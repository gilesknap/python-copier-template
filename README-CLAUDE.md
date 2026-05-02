# Claude sandbox

This project's devcontainer is configured to run Claude Code with
`--allow-dangerously-skip-permissions --permission-mode auto` (see
`justfile`'s `claude` recipe): the bypass-permissions mode is available
on demand, but Claude starts in `auto` mode by default. To make the
bypass option safe, the container is set up as a sandbox: Claude can
use the project toolchain, push/pull through PATs it owns, and persist
its own settings — but it cannot reach back to the host's identity or
shared resources.

This file documents what's locked down, what's deliberately left
exposed, and how to verify the sandbox is intact.

## TL;DR

| Threat | Defence | Verify |
|---|---|---|
| Host VS Code IPC sockets in `/tmp` (`code` CLI, git creds, ssh agent, dev-containers RPC) | Private mount + PID + IPC namespaces; `/tmp` is fresh tmpfs | `/verify-sandbox` checks 4, 7 |
| Capability-gated escapes (`mount`, `bpf`, `pivot_root`, `mknod`) | `setpriv` strips bounding set; `NoNewPrivs` blocks setuid regain | checks 9a, 9b |
| Host SSH / AWS / GCP / Azure / Docker / GPG / X11 credentials on disk | Credential dirs masked with empty tmpfs; single-file creds bound to `/dev/null` | check 5 |
| Host gitconfig (custom credential helpers, `url.insteadOf`, `core.hooksPath`) | `GIT_CONFIG_*` env redirect + bind-mask of `/root/.gitconfig` and `/etc/gitconfig` | check 6 |
| VS Code OAuth popup hijack | Askpass env vars blanked + IPC socket masked | check 2 |
| X11 cookie reuse via shared netns | `DISPLAY`/`XAUTHORITY` blanked, `.Xauthority` bound to `/dev/null`, server refuses handshake | check 11 |
| Token sprawl across projects | Per-folder named volume `devcontainer-private-cache-${localWorkspaceFolderBasename}` mounted at `/private-cache`; `GH_CONFIG_DIR` / `GLAB_CONFIG_DIR` steer the CLIs into it | manual |
| Orphan Claude after parent shell dies | `setpriv --pdeathsig SIGKILL` | manual |

Run `/verify-sandbox` from inside Claude to execute every check.

## Threat model

**Defending against:** a hostile prompt or malicious dependency that
gets code execution as the `claude` process. Such an attacker should
not be able to read host credentials, hijack VS Code's IPC bridges,
modify host gitconfigs, regain capabilities via setuid binaries, or
persist past the shell that launched it.

### Deliberately accepted

| Exposure | Why | Mitigation expected from you |
|---|---|---|
| **Host network namespace** (`--net=host`) — every host interface (`enp5s0`, `tailscale0`, `docker0`, `flannel.1`, …) is visible; every TCP listener on `127.0.0.1` is reachable; Tailscale Magic DNS resolves; LAN hosts answer | Needed for X11, EPICS CA, and to avoid devcontainer port-forwarding hassles | **Treat anything bound to `127.0.0.1` on the host (Ollama, Jupyter, dev servers, Docker daemon on `:2375`, VS Code Server tunnels) as if it were on your LAN.** Sensitive services on tailnet/LAN must have their own auth — don't rely on network position |
| **Sibling repos** under `${localWorkspaceFolder}/..` | Lets `pip install -e ../peer-repo` work and lets Claude read across related projects when asked | Don't keep unrelated sensitive work in the same parent dir |
| **Shared `/cache` volume** (uv, pre-commit, project venv) across all template containers | Faster rebuilds | A poisoned cache spreads to every project sharing the volume |
| **Shared `~/.config/terminal-config/.claude`** | Install a skill once, every devcontainer picks it up | Treat this dir on the host as part of the sandbox boundary, not outside it |
| **No `anthropic.claude-code` IDE integration** — Claude runs CLI-only inside `just claude` | The extension talks to the host VS Code via the same `/tmp` IPC sockets and `VSCODE_IPC_HOOK_CLI` env var the sandbox masks; opening one bridge for it would expose the extension's full API (open files in host editor, drive the clipboard, etc.) to a malicious prompt — re-enabling it defeats the sandbox | Use terminal-side `git diff` / `git log` and copy-paste selection text. Don't add the extension back to `devcontainer.json` |

<details>
<summary>Sharing <code>.claude</code> with a host-side Claude install</summary>

By default the container's `.claude` is independent of any `~/.claude`
on the host. To opt in to sharing, replace the shared dir with a
symlink before the first container build:

```bash
rm -rf ~/.config/terminal-config/.claude    # only if empty / disposable
ln -s ~/.claude ~/.config/terminal-config/.claude
```
</details>

## What's locked down

### Host bridges via VS Code IPC sockets

**Stops:** the `code` CLI, git credential bridge, SSH agent forward,
and Dev Containers RPC — all of which exist as Unix sockets in `/tmp`
and `/run/user/<uid>/`.

**How:** `just claude` calls `unshare -m -p -i --fork --mount-proc`,
giving Claude private mount, PID, and IPC namespaces. `/tmp` and
`/run/user/<uid>/` are fresh tmpfs; the only visible processes are the
ones Claude spawned itself; SysV shared memory / message queues /
semaphores are scoped to the namespace. Bridges still exist in the
parent namespace (VS Code keeps using them normally) but are invisible
to Claude. No race, no sweeper, no recurring check needed.

**Trade-off:** requires `--cap-add=SYS_ADMIN` in `runArgs` for rootless
podman.

<details>
<summary>Mechanism details</summary>

- VS Code re-creates the four bridges (`vscode-ipc-*.sock`,
  `vscode-git-*.sock`, `vscode-ssh-auth-*.sock`,
  `vscode-remote-containers-ipc-*.sock`) on every window attach, and
  they continue to appear up to ~60 s later — see [Demmel's
  writeup][demmel-blog]. Any one-shot cleanup leaves a window;
  namespace separation closes it.
- The mount-ns hides the bridges from `/tmp`; the PID-ns closes the
  `/proc/<other-pid>/root` side-channel that would otherwise let Claude
  dereference an outer process's mount namespace and reach the
  unmasked host `/tmp`; the IPC-ns prevents future host SysV IPC
  segments from leaking in (the host doesn't allocate any today, but
  the boundary is cheap).

[demmel-blog]: https://www.danieldemmel.me/blog/coding-agents-in-secured-vscode-dev-containers
</details>

### Kernel capabilities

**Stops:** `mount(2)`, `pivot_root(2)`, `bpf(2)`, `mknod(S_IFBLK)`, and
any other capability-gated syscall — including those that would bypass
the namespace barrier.

**How:** `claude-sandbox.sh` keeps `CAP_SYS_ADMIN` only long enough to
run its `unshare`/`mount` calls, then `setpriv --bounding-set=-all
--inh-caps=-all --no-new-privs` execs Claude with all capability masks
zeroed. `PR_SET_NO_NEW_PRIVS` blocks any future `execve()` of a setuid
or file-cap binary from regaining privileges.

**Trade-off:** `chown` to a non-root UID returns `EPERM`, so `apt-get
install` postinst scripts that chown logs to system users will fail.
Install system packages from a non-Claude terminal if you need that.

<details>
<summary>Mechanism details</summary>

After `setpriv --bounding-set=-all --inh-caps=-all`, the next
`execve(2)` computes `P'(perm) = (P(inh) | all-ones) & P(bnd) = 0`
because `P(bnd)` is empty. Inside Claude: `CapEff = CapPrm = CapBnd =
CapInh = CapAmb = 0000000000000000`.

</details>

### Host credentials (SSH, AWS, GCP, Azure, Docker, GPG, netrc, X11)

**Stops:** disk reads of host credential dirs and files.

**How:** `unshare -m` lets `claude-sandbox.sh` overlay empty tmpfs on
the directories `/root/.ssh`, `/root/.gnupg`, `/root/.aws`,
`/root/.azure`, `/root/.gcloud`, `/root/.docker`, and bind-mask the
single files `/root/.netrc`, `/root/.Xauthority`, `/root/.ICEauthority`
to `/dev/null` (file masks rather than tmpfs because they're files,
not dirs). `SSH_AUTH_SOCK` is blanked in the namespace exec line so VS
Code's agent forwarding (which the user terminal keeps) cannot reach
Claude.

**Trade-off:** none. You can still bind-mount your host `~/.ssh` (or
`.Xauthority`) into the container for use from regular terminals;
Claude's namespace blanks them.

### Host gitconfigs

**Stops:** custom credential helpers, `url.insteadOf` rewrites,
`core.hooksPath` redirects — anything injectable via
`/root/.gitconfig` or `/etc/gitconfig`.

**How:** two layers.

1. **Env redirect** — the exec line sets
   `GIT_CONFIG_GLOBAL=/etc/claude-gitconfig` and
   `GIT_CONFIG_SYSTEM=/dev/null`, so git itself reads from a curated
   file and ignores the host configs.
2. **Bind-mask** — `mount --bind /dev/null` over `/root/.gitconfig`
   and `/etc/gitconfig` inside Claude's mount namespace, so direct
   file reads (any tool that ignores `GIT_CONFIG_*` and opens the file
   directly) also return empty.

The curated `/etc/claude-gitconfig` contains only the in-container
gh/glab credential helpers, the `git@*:` → `https://` URL rewrites,
`safe.directory = *`, and the user identity (read from the host
gitconfig *before* the bind-mask takes effect, so commits Claude makes
are still attributed).

**Trade-off:** the user's regular terminal keeps the original
`/root/.gitconfig` (host content) — host SSH URL rewrites, custom
credential helpers, and identity all work normally outside Claude.

<details>
<summary>Mechanism details</summary>

The bind lives only inside the per-launch mount namespace; VS Code's
`dev.containers.copyGitConfig` keeps atomically rewriting
`/root/.gitconfig` in the *parent* namespace where our bind is
invisible. Both layers exist because either alone is bypassable: env
vars don't catch tools that open `/root/.gitconfig` directly; bind
mounts don't catch tools that honour `GIT_CONFIG_GLOBAL=...` and never
read the file at all.
</details>

### VS Code OAuth popup

**Stops:** the "log in to GitHub" popup that VS Code surfaces when an
HTTPS git operation needs credentials.

**How:** the exec line blanks `GIT_ASKPASS`, `VSCODE_GIT_IPC_HANDLE`,
`VSCODE_GIT_ASKPASS_NODE`, `VSCODE_GIT_ASKPASS_MAIN`,
`VSCODE_IPC_HOOK_CLI`, `BROWSER`, and `DISPLAY`. The IPC socket the
askpass would talk to lives in `/tmp` (tmpfs-masked). Both layers must
be defeated for Claude to surface a popup.

`DISPLAY` is in the same blank list as the second layer of X11
defence — see the X11 row in the user-vs-Claude table below.

### Continuous verification

`.claude/hooks/sandbox-check.sh` fires on every prompt submit and
refuses to run Claude if `IS_SANDBOX` is unset, `SSH_AUTH_SOCK` is
set, or the path `GIT_ASKPASS` references is reachable. This catches
regressions where an env-blank silently stops being applied.

### Per-folder authentication

**Stops:** token sprawl. Each workspace folder gets its own scoped PATs.

**How:** a single named volume
`devcontainer-private-cache-${localWorkspaceFolderBasename}` is mounted
at `/private-cache`, and `remoteEnv` sets
`GH_CONFIG_DIR=/private-cache/gh` and
`GLAB_CONFIG_DIR=/private-cache/glab` so both CLIs write their auth
state into per-tool subdirs of that volume. Authenticate once with
`just gh-auth` / `just glab-auth`; the tokens survive container
rebuilds.

The volume is the per-devcontainer counterpart to
`devcontainer-shared-cache` (mounted at `/cache`, shared across every
template-derived devcontainer): same caching pattern, but scoped to
this workspace folder. Future per-folder caches can drop subdirs into
`/private-cache/` alongside `gh/` and `glab/`. Two checkouts sharing
the same folder basename will share the volume.

### Process lifetime

**Stops:** orphan Claude after the parent shell dies.

**How:** `setpriv --pdeathsig SIGKILL` on the inner exec sets
`PR_SET_PDEATHSIG`, so if the wrapping `unshare`'d shell exits
(terminal closed, Ctrl-C, etc.) the kernel immediately kills Claude.
No window where the namespace context is gone but Claude is still
running tools.

## User terminal vs Claude

The user terminal runs *outside* Claude's namespace and is set up with
the standard developer experience.

| Feature | User terminal | Claude |
|---|---|---|
| Host gitconfig | Visible (`dev.containers.copyGitConfig`) | Bound to `/dev/null`; `GIT_CONFIG_*` redirected to curated file |
| SSH agent forwarding | `SSH_AUTH_SOCK` set, agent reachable | `SSH_AUTH_SOCK` blanked, socket lives in masked `/tmp` |
| VS Code OAuth popup for HTTPS git | Standard "log in to GitHub" flow | `GIT_ASKPASS` / `VSCODE_GIT_IPC_HANDLE` blanked, IPC socket masked |
| `code` CLI | `VSCODE_IPC_HOOK_CLI` set, opens files in host VS Code | env blanked, socket masked |
| Browser opens | `BROWSER` set | env blanked |
| X11 | `DISPLAY` + `XAUTHORITY` set, cookie at `~/.Xauthority` | both env unset, cookie bound to `/dev/null`; X server connects (shared netns) but refuses handshake without cookie |
| Mount / PID / IPC namespace | Container default | Private (`unshare -m -p -i --fork --mount-proc`) |
| Capabilities | Container default | All masks zero, `NoNewPrivs=1` |

## Verifying the sandbox

Run `/verify-sandbox` from inside `just claude`. The slash command
runs every check documented in `.claude/commands/verify-sandbox.md`
and reports a PASS/FAIL table.

If any check fails, the sandbox is leaking — open an issue against
`python-copier-template`.

<details>
<summary>Manual checks (if you don't have the slash command)</summary>

Run inside `just claude` itself (or in a shell that has `unshare -m`
set up the way `just claude` does). The mount-namespace defences only
apply inside that namespace — a regular VS Code terminal will see the
bridges exactly as VS Code created them, which is correct.

```bash
# Canaries: should be unset (env blanks) and 1 (sandbox marker)
echo "SSH_AUTH_SOCK='${SSH_AUTH_SOCK:-<unset>}'"
echo "GIT_ASKPASS='${GIT_ASKPASS:-<unset>}'"
echo "VSCODE_GIT_IPC_HANDLE='${VSCODE_GIT_IPC_HANDLE:-<unset>}'"
echo "VSCODE_IPC_HOOK_CLI='${VSCODE_IPC_HOOK_CLI:-<unset>}'"
echo "BROWSER='${BROWSER:-<unset>}'"
echo "DISPLAY='${DISPLAY:-<unset>}'"
echo "XAUTHORITY='${XAUTHORITY:-<unset>}'"
echo "IS_SANDBOX='${IS_SANDBOX:-<unset>}'"          # should be 1
ssh-add -l                                          # "Could not open a connection..."

# /tmp and /run/user should be empty tmpfs inside Claude's namespace.
ls /tmp                                             # only claude-* runtime dirs
ls /run/user/*/ 2>/dev/null                         # nothing matching vscode-*
mount | grep -E ' on /tmp |/run/user'               # tmpfs entries from claude-sandbox.sh

# PID namespace: this script should be PID 1, /proc should only see
# sandbox processes, and /proc/1/root must point at the same mount
# namespace we're in (so it cannot be used to reach the host /tmp).
[ "$(readlink /proc/1/ns/mnt)" = "$(readlink /proc/self/ns/mnt)" ]  # exit 0
ls /proc/1/root/tmp/ | grep -E '^vscode-' && echo LEAK || echo OK

# Capabilities: setpriv must have stripped the bounding set before exec,
# so claude-the-binary runs with CapEff=CapBnd=0. NoNewPrivs blocks
# regaining caps via setuid/file-cap binaries.
grep -E '^Cap(Eff|Bnd|Inh|Amb)' /proc/self/status   # all 0000000000000000
grep ^NoNewPrivs /proc/self/status                  # NoNewPrivs: 1

# IPC namespace: SysV IPC tables visible from inside should hold no
# host-allocated segments (they would have non-root cuid/cgid).
cat /proc/sysvipc/shm /proc/sysvipc/msg /proc/sysvipc/sem  # only headers

# /root/.ssh and friends should be empty even if you bind-mount the host
# originals via devcontainer.json — Claude's namespace masks them.
# .Xauthority / .ICEauthority / .netrc are bound to /dev/null (file masks
# rather than tmpfs because they're files, not dirs).
ls /root/.ssh /root/.gnupg /root/.aws 2>/dev/null   # all empty (or missing)
cat /root/.Xauthority /root/.ICEauthority /root/.netrc 2>/dev/null  # all empty

# Gitconfig defence: env vars steer git, bind-mounts to /dev/null close
# the direct-file-read path. Both must be in place.
echo "$GIT_CONFIG_GLOBAL"                           # /etc/claude-gitconfig
echo "$GIT_CONFIG_SYSTEM"                           # /dev/null
cat /root/.gitconfig                                # empty (bound to /dev/null)
cat /etc/gitconfig                                  # empty (bound to /dev/null)
git config --global --list | grep -E 'credential|insteadof'  # curated only
git config --system --list                          # empty (reads /dev/null)

# X11 server is unauthenticated from inside: connect succeeds (shared net
# ns) but handshake is refused without a cookie. First reply byte 0x00
# is "refused" (PASS), 0x01 is "accepted" (LEAK), 0x02 is "auth required"
# (LEAK — server willing to accept a cookie if Claude can find one).
python3 -c "
import socket, struct
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('\0/tmp/.X11-unix/X0')
s.sendall(struct.pack('=BxHHHHxx', ord('l'), 11, 0, 0, 0))
b = s.recv(1)
print('X11 first byte:', b.hex(), '(00=refused PASS, 01=accepted LEAK, 02=auth-required LEAK)')
"

# Should return creds only if `just gh-auth` has been run for this repo.
printf 'protocol=https\nhost=github.com\n\n' | git credential fill
```

If `git credential fill` returns a `password=gho_...` for github.com
when you have not run `just gh-auth`, or if `ls /tmp` shows any
`vscode-*` entries inside the namespace, or if the X11 first reply
byte is anything but `0x00`, the sandbox is leaking — open an issue
against `python-copier-template`.

</details>

## Authenticating

```bash
just gh-auth     # paste a github.com PAT (repo + workflow scope is enough)
just glab-auth   # gitlab.com  (pass a hostname arg for self-hosted instances)
```

## Starting Claude

```bash
just claude      # runs `claude --allow-dangerously-skip-permissions --permission-mode auto` inside the mount namespace
```
