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
- **No host SSH keys, AWS/GCP/Azure/Docker credentials, GPG keys, or
  netrc.** The same `unshare -m` masks `/root/.ssh`, `/root/.gnupg`,
  `/root/.aws`, `/root/.azure`, `/root/.gcloud`, `/root/.docker`, and
  `/root/.netrc` (where present) with empty tmpfs. This means you *can*
  bind-mount your host `~/.ssh` into the container if you want to use
  SSH keys from a regular terminal — Claude's namespace blanks them out
  while non-Claude shells see the originals. `SSH_AUTH_SOCK` is blanked
  in the namespace exec line so VS Code's agent forwarding (which the
  user terminal keeps) cannot reach Claude.
- **Claude dies with its parent shell.** `setpriv --pdeathsig SIGKILL`
  on the inner `claude` exec sets `PR_SET_PDEATHSIG`, so if the wrapping
  `unshare`'d shell exits (terminal closed, Ctrl-C, etc.) the kernel
  immediately kills Claude — there's no orphaned-claude window where the
  namespace context is gone but Claude is still running tools.
- **Claude has its own `/root/.gitconfig` via bind-mount.**
  `claude-sandbox.sh` writes `/etc/claude-gitconfig` containing only the
  in-container gh/glab credential helpers, the `git@*:` → `https://`
  url rewrites, `safe.directory = *`, and the user identity (read from
  the host-copied gitconfig before we bind over it, so commits Claude
  makes are still attributed). It then `mount --bind`s that file onto
  `/root/.gitconfig` inside Claude's namespace. The user's regular
  terminal keeps the original `/root/.gitconfig` (host content, copied
  by `dev.containers.copyGitConfig`'s default), so the host's SSH url
  rewrites, custom credential helpers, and identity all work normally
  outside Claude — but Claude only ever sees the curated config.
  `/etc/gitconfig` (system scope) is also masked: VS Code dev-container
  images bake a `credential.helper` there that shells out via
  `/tmp/vscode-remote-containers-*.js`, so `claude-sandbox.sh` binds
  `/dev/null` over it inside the namespace.
- **The "log in to GitHub" popup is closed for Claude.** The user
  terminal keeps `git.terminalAuthentication` at its default (true), so
  `GIT_ASKPASS` and `VSCODE_GIT_IPC_HANDLE` are injected into terminals
  and the user gets the natural VS Code OAuth popup when an HTTPS git
  operation needs credentials. For Claude two things close that channel:
  `claude-sandbox.sh`'s exec line blanks `GIT_ASKPASS`,
  `VSCODE_GIT_IPC_HANDLE`, `VSCODE_GIT_ASKPASS_NODE`,
  `VSCODE_GIT_ASKPASS_MAIN`, `VSCODE_IPC_HOOK_CLI`, and `BROWSER`; and
  the IPC socket the askpass script would talk to lives in `/tmp`,
  which is tmpfs-masked. Both layers must be defeated for Claude to
  surface a popup.

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
  bind-mount; the user terminal sees the original.
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

- **`/root/.claude` is bind-mounted from the host's `~/.claude`.** Claude's
  settings, memory, hooks, and skills are shared between the host and the
  container — that's the whole point. Anything Claude writes to its own
  config persists to the host home directory. Treat `~/.claude` on the
  host as part of the sandbox boundary, not outside it.
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
ls /root/.ssh /root/.gnupg /root/.aws 2>/dev/null   # all empty (or missing)

# Claude's bind-mounted gitconfig: only gh/glab helpers + HTTPS rewrites,
# no host SSH url rewrites or unrelated host helpers.
git config --global --list | grep -E 'credential|insteadof'
mount | grep '/root/.gitconfig'                     # bind from /etc/claude-gitconfig
git config --system --get credential.helper         # should exit non-zero
mount | grep '/etc/gitconfig'                       # bind from /dev/null

# Should return creds only if `just gh-auth` has been run for this repo.
printf 'protocol=https\nhost=github.com\n\n' | git credential fill
```

If `git credential fill` returns a `password=gho_...` for github.com when
you have not run `just gh-auth`, or if `ls /tmp` shows any `vscode-*`
entries inside the namespace, the sandbox is leaking — open an issue
against the python-copier-template.

## Authenticating

```bash
just gh-auth     # paste a github.com PAT (repo + workflow scope is enough)
just glab-auth   # gitlab.com  (pass a hostname arg for self-hosted instances)
```

## Starting Claude

```bash
just claude      # runs `claude --allow-dangerously-skip-permissions --permission-mode auto` inside the mount namespace
```

After a rebuild from a previous version of this template, the user
terminal's `/root/.gitconfig` may still carry HTTPS rewrites or per-host
helpers that older `postStart.sh` runs added globally. Either rebuild
the devcontainer for a clean state, or `git config --global --unset-all`
the affected keys.
