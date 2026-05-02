# Claude sandbox

This project's devcontainer is configured to run Claude Code with
`--allow-dangerously-skip-permissions --permission-mode auto` (see `justfile`'s
`claude` recipe): the bypass-permissions mode is available on demand, but
Claude starts in `auto` mode by default. To make the bypass option safe, the
container is set up as a sandbox: Claude can use the project toolchain,
push/pull through PATs it owns, and persist its own settings — but it cannot
reach back to the host's identity or shared resources.

This file documents what's locked down, what's deliberately left exposed,
and how to verify the sandbox is intact.

## What's locked down

- **No host bridges via VS Code IPC sockets.** VS Code's server creates
  several unix sockets in `/tmp` and `/run/user/<uid>/` that are bridges
  back to the host: `vscode-ipc-*.sock` (runs `code` CLI on the host),
  `vscode-git-*.sock` (git credential bridge — surfaces host PATs),
  `vscode-ssh-auth-*.sock` (host SSH agent forward), and
  `vscode-remote-containers-ipc-*.sock` (Dev Containers extension RPC).
  These are re-created on every window attach and continue to appear up
  to ~60s later — see [the threat-model writeup][demmel-blog] — so any
  one-shot cleanup leaves a window. The defence is the **`unshare -m -p
  -i --fork --mount-proc`** call in `just claude`: Claude runs in
  private mount, PID, and IPC namespaces. `/tmp` and `/run/user/<uid>/`
  are fresh tmpfs; the only visible processes are the ones Claude
  spawned itself; SysV shared memory / message queues / semaphores are
  scoped to the namespace. The mount-namespace hides the bridges from
  Claude's /tmp; the PID-namespace closes the `/proc/<other-pid>/root`
  side-channel that would otherwise let Claude dereference an outer
  process's mount namespace and reach the unmasked host /tmp; the
  IPC-namespace prevents future host SysV IPC segments from leaking
  in (the host doesn't allocate any today, but the boundary is cheap).
  The bridges still exist in the parent namespace (VS Code keeps using
  them normally) but are invisible to Claude. No race, no sweeper, no
  recurring check needed. Requires `--cap-add=SYS_ADMIN` in `runArgs`
  for rootless podman.

  [demmel-blog]: https://www.danieldemmel.me/blog/coding-agents-in-secured-vscode-dev-containers
- **Claude runs with no kernel capabilities.** `claude-sandbox.sh` needs
  `CAP_SYS_ADMIN` for its `unshare`/`mount` calls, but by the time
  mounts are done that capability is no longer useful — only dangerous.
  The final `setpriv` exec passes `--bounding-set=-all --inh-caps=-all
  --no-new-privs`, so the bounding set is empty when claude-the-binary
  starts and `P'(perm) = (P(inh) | all-ones) & P(bnd) = 0` — `CapEff`,
  `CapPrm`, and `CapBnd` are all `0000000000000000` inside Claude.
  This neuters several capability-gated escape paths (`mount(2)`,
  `pivot_root(2)`, `bpf(2)`, `mknod(S_IFBLK)`) at the cap check, on top
  of the existing user-namespace barrier. `PR_SET_NO_NEW_PRIVS` blocks
  any future `execve()` of a setuid or file-cap binary from regaining
  privileges. Trade-off: `chown` to a non-root UID returns `EPERM`, so
  `apt-get install` postinst scripts that chown logs to system users
  will fail; install system packages from a non-Claude terminal if you
  need that.
- **No host SSH keys, AWS/GCP/Azure/Docker credentials, GPG keys, netrc,
  or X11 cookies.** The same `unshare -m` masks the credential
  directories `/root/.ssh`, `/root/.gnupg`, `/root/.aws`, `/root/.azure`,
  `/root/.gcloud`, `/root/.docker` with empty tmpfs, and bind-masks the
  single-file credentials `/root/.netrc`, `/root/.Xauthority`, and
  `/root/.ICEauthority` to `/dev/null`. This means you *can* bind-mount
  your host `~/.ssh` (or `.Xauthority`) into the container if you want
  to use them from a regular terminal — Claude's namespace blanks them
  out while non-Claude shells see the originals. `SSH_AUTH_SOCK` is
  blanked in the namespace exec line so VS Code's agent forwarding
  (which the user terminal keeps) cannot reach Claude.
- **Claude dies with its parent shell.** `setpriv --pdeathsig SIGKILL`
  on the inner `claude` exec sets `PR_SET_PDEATHSIG`, so if the wrapping
  `unshare`'d shell exits (terminal closed, Ctrl-C, etc.) the kernel
  immediately kills Claude — there's no orphaned-claude window where the
  namespace context is gone but Claude is still running tools.
- **Claude's git is redirected away from the host gitconfigs in two
  layers.** `claude-sandbox.sh` writes `/etc/claude-gitconfig`
  containing only the in-container gh/glab credential helpers, the
  `git@*:` → `https://` url rewrites, `safe.directory = *`, and the
  user identity (read from the host-copied gitconfig *before* the
  bind mask below takes effect, so commits Claude makes are still
  attributed). Layer 1: the exec line sets
  `GIT_CONFIG_GLOBAL=/etc/claude-gitconfig` and
  `GIT_CONFIG_SYSTEM=/dev/null`, so git itself reads from the curated
  file and ignores `/root/.gitconfig` (host per-user config) and
  `/etc/gitconfig` (host system-scope credential helper). Layer 2: a
  `mount --bind /dev/null` over each of those two paths inside Claude's
  mount namespace, so that direct file reads (`cat /root/.gitconfig`,
  or any tool that ignores `GIT_CONFIG_*` and opens the file directly)
  also return empty. The bind lives only inside the per-launch mount
  ns; VS Code's `dev.containers.copyGitConfig` keeps atomically
  rewriting `/root/.gitconfig` in the *parent* namespace where our
  bind is invisible. The user's regular terminal keeps the original
  `/root/.gitconfig` (host content), so the host's SSH url rewrites,
  custom credential helpers, and identity all work normally outside
  Claude.
- **The "log in to GitHub" popup is closed for Claude.** The user
  terminal keeps `git.terminalAuthentication` at its default (true), so
  `GIT_ASKPASS` and `VSCODE_GIT_IPC_HANDLE` are injected into terminals
  and the user gets the natural VS Code OAuth popup when an HTTPS git
  operation needs credentials. For Claude two things close that channel:
  `claude-sandbox.sh`'s exec line blanks `GIT_ASKPASS`,
  `VSCODE_GIT_IPC_HANDLE`, `VSCODE_GIT_ASKPASS_NODE`,
  `VSCODE_GIT_ASKPASS_MAIN`, `VSCODE_IPC_HOOK_CLI`, `BROWSER`, and
  `DISPLAY`; and the IPC socket the askpass script would talk to lives
  in `/tmp`, which is tmpfs-masked. Both layers must be defeated for
  Claude to surface a popup. `DISPLAY` is in the same blank list to
  stop Claude from finding the host X server by environment — see the
  abstract-socket discussion under `--net=host` below for the second
  layer of X11 defence.

  `.claude/hooks/sandbox-check.sh` is the periodic verifier: it fires
  on every prompt submit and refuses to run Claude if `IS_SANDBOX` is
  unset, `SSH_AUTH_SOCK` is set, or the path `GIT_ASKPASS` references
  is reachable.
- **Auth is per-repo.** `gh-auth-${repo}` and `glab-auth-${repo}` are
  named volumes, not bind mounts — each project gets its own scoped PAT
  via `just gh-auth` / `just glab-auth`. Authenticate once per repo and
  the token survives container rebuilds.

## What the user terminal gets (and why)

VS Code's regular terminal runs *outside* Claude's namespace. It is
deliberately set up with the standard developer experience so working
in the devcontainer feels natural:

- **Host gitconfig copied in.** `dev.containers.copyGitConfig` defaults
  to true, so `/root/.gitconfig` carries the user's name, email, push
  preferences, and any host url rewrites. Claude overrides this via
  `GIT_CONFIG_*` env vars plus a bind-mount to `/dev/null` inside its
  namespace; the user terminal sees the original.
- **SSH agent forwarding.** VS Code forwards the host SSH agent into
  the container as it normally would; `SSH_AUTH_SOCK` points at
  `/tmp/vscode-ssh-auth-*.sock`. Inside Claude's namespace `/tmp` is
  tmpfs and the variable is blanked, so Claude cannot reach the agent.
- **VS Code OAuth popup for HTTPS git.** `git.terminalAuthentication`
  is left at its default, so when an HTTPS git operation needs creds
  the user gets the standard "log in to GitHub" popup. Claude's exec
  blanks `GIT_ASKPASS` / `VSCODE_GIT_IPC_HANDLE` and masks the IPC
  socket path, so the popup channel does not exist for Claude.
- **`code` CLI and host browser.** `VSCODE_IPC_HOOK_CLI` and `BROWSER`
  are inherited by the user terminal so `code <file>` and tools that
  open URLs do the natural thing. Both env vars are blanked in
  Claude's exec and the sockets they reference live in `/tmp`.

## What's deliberately exposed (and why)

- **`/root/.claude` is bind-mounted from `~/.config/terminal-config/.claude`.**
  Claude's settings, memory, hooks, and skills live in a shared location
  under `terminal-config`, so every devcontainer built from this template
  sees the same `.claude` — install a skill once and every project picks
  it up. Anything Claude writes to its own config persists there. Treat
  `~/.config/terminal-config/.claude` on the host as part of the sandbox
  boundary, not outside it.

  To share with a host-side Claude install, opt in by replacing the
  shared dir with a symlink before the first container build:

  ```bash
  rm -rf ~/.config/terminal-config/.claude    # only if empty / disposable
  ln -s ~/.claude ~/.config/terminal-config/.claude
  ```

  Without the symlink the container's `.claude` is independent of any
  `~/.claude` you may have on the host.
- **`/workspaces` is the parent of the project, not the project itself.**
  The `workspaceMount` source is `${localWorkspaceFolder}/..`, so all
  sibling repos in the same parent directory are visible inside the
  container. This is intentional — it lets `pip install -e ../peer-repo`
  work and lets Claude read across related projects when asked. If you
  keep unrelated work in the same parent dir, Claude can see it.
- **`--net=host` shares the host's network namespace.** The container's
  hostname will match the host's, and any service bound to `localhost` on
  the host is reachable from inside. This is needed for X11, EPICS CA,
  and to avoid devcontainer port-forwarding hassles. It also means the
  container can talk to anything the host can talk to on its LAN.
  Claude's `unshare -m -p` does not add `-n`, so this exposure extends
  into the sandbox: Claude can reach host TCP listeners on `127.0.0.1`
  (sshd, dev servers, kubelet, etc.) and abstract-namespace unix sockets
  (e.g. `@/tmp/.X11-unix/X0`) which are net-ns scoped rather than mount-ns
  scoped. The pathname-bound VS Code IPC sockets in `/tmp` are still
  defended — those resolve through the mount namespace and `connect(2)`
  fails with `ENOENT` from inside the sandbox — but anything authenticated
  only by "the caller is on localhost" should be assumed reachable. Don't
  run unauthenticated services with secrets bound to `127.0.0.1` while
  using Claude.

  The X11 abstract socket is reachable but not usable: `DISPLAY` is
  blanked, `XAUTHORITY` is unset, and `/root/.Xauthority` /
  `/root/.ICEauthority` are bind-masked to `/dev/null`. A connect to
  `@/tmp/.X11-unix/X0` succeeds at the kernel layer but the X server
  rejects the protocol handshake with "Authorization required" — no
  `XQueryKeymap`, `XGetImage`, or `XTestFakeKeyEvent` is reachable
  without the cookie. Both the env-blank and the cookie-mask must be
  defeated for an X11 attack to land.
- **`/cache` is a shared named volume across all devcontainers** built
  from this template — uv cache, pre-commit cache, and the project venv
  live there. Faster rebuilds; the trade-off is that a poisoned cache
  affects every project sharing the volume.

## Verifying the sandbox

Run inside `just claude` itself (use Claude's bash tool, or run the same
commands manually after dropping into a shell that has `unshare -m` set
up the way `just claude` does). The mount-namespace defences only apply
inside that namespace — a regular VS Code terminal will see the bridges
exactly as VS Code created them, which is correct.

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

If `git credential fill` returns a `password=gho_...` for github.com when
you have not run `just gh-auth`, or if `ls /tmp` shows any `vscode-*`
entries inside the namespace, or if the X11 first reply byte is anything
but `0x00`, the sandbox is leaking — open an issue against the
python-copier-template.

## Authenticating

```bash
just gh-auth     # paste a github.com PAT (repo + workflow scope is enough)
just glab-auth   # gitlab.com  (pass a hostname arg for self-hosted instances)
```

## Starting Claude

```bash
just claude      # runs `claude --allow-dangerously-skip-permissions --permission-mode auto` inside the mount namespace
```
