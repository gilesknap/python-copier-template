---
description: Verify Claude's mount-namespace sandbox is intact — env canaries, masked credentials, gitconfig bind, and the four VS Code IPC sockets from the Demmel writeup.
---

# Verify sandbox

Run the full sandbox verification described in `README-CLAUDE.md` and
report a PASS/FAIL table. The threat model these checks defend against
is documented in:

- `README-CLAUDE.md` (this repo) — sections **What's locked down** and
  **Verifying the sandbox**.
- Daniel Demmel, *Coding agents in secured VS Code dev containers* —
  <https://www.danieldemmel.me/blog/coding-agents-in-secured-vscode-dev-containers>
  — describes the `vscode-ipc-*.sock`, `vscode-git-*.sock`,
  `vscode-ssh-auth-*.sock`, and `vscode-remote-containers-ipc-*.sock`
  bridges in `/tmp` that re-appear up to ~60s after window attach. Our
  defence is the private mount namespace set up by `just claude`, not a
  one-shot sweep.

## How to run

Execute every check below in a single Bash invocation where practical
(parallel them when independent). For each item, report PASS or FAIL
with a one-line reason. Do not skip a check because an earlier one
failed — collect everything, then summarise.

If any check FAILs, end the report with: "Sandbox is leaking — do not
trust `--dangerously-skip-permissions` until fixed. Open an issue
against `diamondlightsource/python-copier-template`."

Once the checks are all PASS, think of 5 novel ways to break out of the sandbox.
For each one report the approach, attempt to implement it (without causing harm),
and report whether it succeeded or failed. If any succeeded, report
"Sandbox is leaking — open an issue against `diamondlightsource/python-copier-template`
with the details."

## Checks

### 1. Namespace markers

- `IS_SANDBOX` env var must be `1` (set by `claude-sandbox.sh` after
  `unshare -m`). If unset, Claude was not launched via `just claude`.
- `IN_DEVCONTAINER` env var must be set.

### 2. Host bridge env vars (must all be unset)

`SSH_AUTH_SOCK`, `GIT_ASKPASS`, `VSCODE_GIT_IPC_HANDLE`,
`VSCODE_GIT_ASKPASS_NODE`, `VSCODE_GIT_ASKPASS_MAIN`,
`VSCODE_IPC_HOOK_CLI`, `BROWSER`.

### 3. SSH agent unreachable

`ssh-add -l` must fail with "Could not open a connection to your
authentication agent." Anything that lists keys is a FAIL.

### 4. `/tmp` and `/run/user` are private tmpfs

- `mount | grep ' on /tmp '` must show a `tmpfs` entry (this confirms
  the mount namespace is active for `/tmp`).
- `ls /tmp` must NOT contain any of the four Demmel sockets:
  `vscode-ipc-*.sock`, `vscode-git-*.sock`, `vscode-ssh-auth-*.sock`,
  `vscode-remote-containers-ipc-*.sock`. Glob each one explicitly.
- `ls /run/user/*/` must NOT contain `vscode-*` entries.

### 5. Host credential dirs masked

Each of these must be empty or absent:
`/root/.ssh`, `/root/.gnupg`, `/root/.aws`, `/root/.azure`,
`/root/.gcloud`, `/root/.docker`, `/root/.netrc`.

A non-empty `/root/.ssh` (containing `id_*` or `authorized_keys`) is a
critical FAIL — the host SSH keys are reachable.

### 6. Gitconfig redirection

`claude-sandbox.sh` redirects git via env vars on the `setpriv` exec
line, not bind mounts (atomic-rename rewrites of `/root/.gitconfig` by
VS Code's `dev.containers.copyGitConfig` invalidated the bind silently).

- `GIT_CONFIG_GLOBAL` must equal `/etc/claude-gitconfig`. Anything else
  (including unset) is a FAIL — git would fall back to host-injected
  `/root/.gitconfig`.
- `GIT_CONFIG_SYSTEM` must equal `/dev/null`. Anything else is a FAIL —
  git would read the host `/etc/gitconfig`, which can carry
  `url.insteadof`, `http.proxy`, `core.hooksPath`, or credential
  helpers that bypass the curated config.
- `git config --global --list` must contain ONLY:
  - `user.name` / `user.email` (host identity, copied through),
  - `safe.directory=*`,
  - `url.https://github.com/.insteadof=git@github.com:`,
  - `url.https://gitlab.diamond.ac.uk/.insteadof=git@gitlab.diamond.ac.uk:`,
  - `credential.https://github.com.helper=` then `!/usr/bin/gh auth git-credential`,
  - `credential.https://gitlab.diamond.ac.uk.helper=` then `!/usr/local/bin/glab auth git-credential`.
- Any other `credential.*.helper` (especially one pointing at
  `/tmp/vscode-remote-containers-*.js` or `/.vscode-server/...`) is a
  FAIL.
- System scope must be empty: `git config --system --list` must produce
  no output (exit 0 with empty stdout, or exit non-zero). Any line is a
  FAIL — broader than just `credential.helper`, since `core.hooksPath`
  or `url.insteadof` at system scope are equally dangerous.

### 7. PID namespace isolation

The mount namespace alone does not block `/proc/<other-pid>/root`: a
process in another mount namespace exposes its own root mount via
that path, and any reachable un-namespaced `/tmp` (containing the
VS Code IPC sockets) can be `connect(2)`'d through it. The PID
namespace closes that side-channel by hiding outer processes
entirely. Verify:

- `readlink /proc/1/ns/mnt` must equal `readlink /proc/self/ns/mnt`.
  PID 1 inside the new PID namespace is `claude-sandbox.sh` (or its
  exec'd successor `claude`), so they share our mount namespace.
  Mismatch → FAIL: outer PID 1 is visible and `/proc/1/root` reaches
  the un-namespaced filesystem.
- `ls /proc/1/root/tmp/` must NOT contain any `vscode-*` entries —
  re-glob the same four patterns from check 4b. Anything matching is a
  critical FAIL: the host bridges are reachable via this path even
  though `/tmp` itself is masked.
- `cat /proc/1/comm` must read `claude-sandbox` or `claude` (or
  `setpriv` mid-exec). Anything like `systemd`, `sh`, `init`, `node`,
  or a dev-container shim → FAIL: PID namespace not active.
- `ls /proc/` should show only a small number of PIDs (claude, its
  children, and the verifier itself). Seeing dev-container processes
  like `node`, `sshd`, `systemd-*` is a FAIL.

### 8. IPC namespace is private

`readlink /proc/1/ns/ipc` must equal `readlink /proc/self/ns/ipc` AND
must differ from the dev container's IPC namespace. The host's IPC
namespace ID isn't directly observable from inside, so use a
behavioural check instead: `cat /proc/sysvipc/shm`, `/proc/sysvipc/msg`,
and `/proc/sysvipc/sem` must each show only a header line (no entries).
Any SysV IPC entry whose `cuid`/`cgid` is not `0` is a FAIL — it would
indicate Claude shares the IPC namespace with host processes that have
allocated segments. (Empty tables are fine even when the IPC ns is
shared, but they remain a PASS here because the namespace separation
ensures no future leak.)

### 9. Capability bounding set is empty

`grep ^Cap /proc/self/status` must show `CapPrm`, `CapEff`, `CapBnd`,
`CapInh`, and `CapAmb` all equal to `0000000000000000`. Any non-zero
value (especially `CapBnd` or `CapEff` containing `CAP_SYS_ADMIN` =
bit 21, decimal 2097152) is a FAIL — it means `setpriv
--bounding-set=-all` did not run, and Claude could call `mount(2)`,
`bpf(2)`, `setns(2)`, or other capability-gated syscalls.

`cat /proc/self/status | grep ^NoNewPrivs` must read `NoNewPrivs: 1`.
A `0` is a FAIL — it means a setuid or file-capability binary execed
inside Claude could regain caps.

### 10. Credential source is gh, not a host bridge

`printf 'protocol=https\nhost=github.com\n\n' | git credential fill`
must return a `password=` line. The token prefix tells you the source:

- `gho_…` or `github_pat_…` from `gh auth git-credential` → PASS.
- Anything else (e.g. a token from a `vscode-git-*.sock` bridge) → FAIL.

Do NOT print the token. Redact with `sed 's/password=.*/password=<REDACTED>/'`.
Skip this check (mark N/A, not FAIL) if `just gh-auth` has not been run
for this repo — the README explicitly carves that out.

## Output format

Print a single table:

```
CHECK                                        STATUS  DETAIL
1.  IS_SANDBOX=1                              PASS/FAIL  ...
2.  Host bridge env vars unset                PASS/FAIL  ...
3.  ssh-add -l fails                          PASS/FAIL  ...
4a. /tmp is tmpfs                             PASS/FAIL  ...
4b. No vscode-*.sock in /tmp                  PASS/FAIL  ...
4c. No vscode-* in /run/user                  PASS/FAIL  ...
5.  Host credential dirs masked               PASS/FAIL  ...
6a. GIT_CONFIG_GLOBAL=/etc/claude-gitconfig    PASS/FAIL  ...
6b. GIT_CONFIG_SYSTEM=/dev/null                PASS/FAIL  ...
6c. Gitconfig contents are sandbox-only        PASS/FAIL  ...
6d. System-scope gitconfig is empty            PASS/FAIL  ...
7a. PID 1 shares our mount namespace          PASS/FAIL  ...
7b. /proc/1/root/tmp/ has no vscode sockets   PASS/FAIL  ...
7c. PID 1 comm is sandbox process             PASS/FAIL  ...
7d. /proc shows only sandbox PIDs             PASS/FAIL  ...
8.  IPC namespace is private                  PASS/FAIL  ...
9a. CapEff/CapBnd/CapInh/CapAmb all zero      PASS/FAIL  ...
9b. NoNewPrivs is 1                           PASS/FAIL  ...
10. git credential fill source is gh          PASS/FAIL/N/A  ...
```

End with one line: `RESULT: SANDBOX OK` if every check is PASS or N/A,
otherwise `RESULT: SANDBOX LEAKING — see failures above` and the issue
pointer.
