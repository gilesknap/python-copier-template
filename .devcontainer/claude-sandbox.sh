#!/bin/bash
# Inner script for `just claude`: runs inside private mount, PID, and
# IPC namespaces (created by `unshare -m -p -i --fork --mount-proc` in
# the justfile recipe). Tmpfs-masks the directories VS Code uses for
# host bridges, bind-masks the host gitconfigs and X11 cookies inside
# this namespace, writes a Claude-only /etc/claude-gitconfig, and
# exec's claude with GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM steering git
# at the curated config — plus PR_SET_PDEATHSIG (so claude dies if the
# wrapping shell does), an empty capability bounding set, and
# PR_SET_NO_NEW_PRIVS (so Claude runs with CapEff=0 and cannot regain
# caps via setuid binaries or file caps). Bind mounts are safe here
# because they live only inside this per-launch mount ns; VS Code's
# dev.containers.copyGitConfig rewrites /root/.gitconfig in the parent
# ns where our binds are invisible, so the historical atomic-rename
# invalidation that bit a postCreate-time bind doesn't apply.
# See README-CLAUDE.md for the full sandbox model.
# Requires CAP_SYS_ADMIN — granted via --cap-add=SYS_ADMIN in
# devcontainer.json's runArgs — for the unshare and mount calls; the
# cap is dropped on the final exec.
set -euo pipefail

# VS Code drops IPC sockets (vscode-ipc-*.sock, vscode-git-*.sock,
# vscode-ssh-auth-*.sock, vscode-remote-containers-ipc-*.sock) and the
# vscode-remote-containers-*.js credential shim in /tmp, plus more in
# /run/user/<uid>/. Replacing those directories with tmpfs in Claude's
# namespace makes them invisible. Outside the namespace (the user's
# regular terminal) VS Code keeps using them normally.
mount -t tmpfs tmpfs /tmp
if [ -d /run/user ]; then
    mount -t tmpfs tmpfs /run/user
fi

# Mask credential directories the user may bind-mount from the host for
# their own use from non-Claude terminals (e.g. ~/.ssh for SSH-based
# git push). Claude sees an empty tmpfs; the user's regular shell sees
# the originals.
for d in /root/.ssh /root/.gnupg /root/.aws /root/.azure /root/.gcloud /root/.docker; do
    if [ -d "$d" ]; then
        mount -t tmpfs tmpfs "$d"
    fi
done
# Build a Claude-only gitconfig at /etc/claude-gitconfig containing the
# in-container credential helpers (gh / glab) and HTTPS rewrites — and
# nothing else the user has on the host (no SSH url rewrites, no
# host-specific helpers). User identity is read from the original
# gitconfig BEFORE the bind mask below takes effect, so commits Claude
# makes are still attributed. Hardcode the gh/glab paths — `command -v`
# could resolve to a `.vscode-server`-pathed binary in some setups and
# embed that string into our helper line, which would later trip the
# sandbox-check hook on what looks like a VS Code credential bridge.
git_name=$(git config --get user.name 2>/dev/null || true)
git_email=$(git config --get user.email 2>/dev/null || true)
cat > /etc/claude-gitconfig <<EOF
[user]
    name = $git_name
    email = $git_email
[safe]
    directory = *
[url "https://github.com/"]
    insteadOf = git@github.com:
[url "https://gitlab.diamond.ac.uk/"]
    insteadOf = git@gitlab.diamond.ac.uk:
[credential "https://github.com"]
    helper =
    helper = !/usr/bin/gh auth git-credential
[credential "https://gitlab.diamond.ac.uk"]
    helper =
    helper = !/usr/local/bin/glab auth git-credential
EOF

# Single-file masks via bind to /dev/null. Done AFTER /etc/claude-gitconfig
# is written and after `git config --get` has captured the user's identity,
# so the curated config has the host name/email but Claude can't read the
# host gitconfigs directly:
# - /root/.gitconfig, /etc/gitconfig: host gitconfigs may carry url rewrites,
#   credential helpers, or core.hooksPath that bypass the curated config.
#   Belt-and-braces with GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM on the exec
#   line — env vars steer git itself; the bind closes the direct-file-read
#   path that ignores env. The bind lives only inside this per-launch mount
#   ns; VS Code's dev.containers.copyGitConfig rewrites /root/.gitconfig in
#   the parent ns where our bind is invisible.
# - .netrc: host HTTPS/FTP creds the user may bind-mount in.
# - .Xauthority / .ICEauthority: MIT-MAGIC-COOKIE for the host X server.
#   Without the cookie, an X11 connect through the shared net ns to the
#   abstract socket @/tmp/.X11-unix/X0 fails the handshake — the server
#   replies with "Authorization required" and closes. Defence-in-depth
#   for the day someone bind-mounts the cookie in for legit X11 use.
for f in /root/.gitconfig /etc/gitconfig \
         /root/.netrc /root/.Xauthority /root/.ICEauthority; do
    if [ -e "$f" ]; then
        mount --bind /dev/null "$f"
    fi
done

# IS_SANDBOX=1 is the canary `.claude/hooks/sandbox-check.sh` keys off.
# Env-blanks: SSH_AUTH_SOCK / VSCODE_GIT_IPC_HANDLE / VSCODE_IPC_HOOK_CLI
# all point into /tmp (already tmpfs in this namespace), but blanking
# the vars stops Claude from even *trying* the path. GIT_ASKPASS and
# VSCODE_GIT_ASKPASS_* point under /.vscode-server which the namespace
# does NOT mask — blanking them is the actual defence against Claude
# triggering the VS Code "log in to GitHub" popup. BROWSER points at a
# host helper that opens URLs in the user's browser — blanked so
# Claude cannot drive the user's browser. DISPLAY is blanked so Claude
# cannot find the host X server by environment — the abstract socket
# is reachable across the shared net ns but the X protocol handshake
# is refused without a MIT-MAGIC-COOKIE (see .Xauthority mask above).
exec setpriv \
    --pdeathsig SIGKILL \
    --no-new-privs \
    --inh-caps=-all \
    --bounding-set=-all \
    env \
    SSH_AUTH_SOCK= \
    GIT_ASKPASS= \
    VSCODE_GIT_IPC_HANDLE= \
    VSCODE_GIT_ASKPASS_NODE= \
    VSCODE_GIT_ASKPASS_MAIN= \
    VSCODE_IPC_HOOK_CLI= \
    BROWSER= \
    DISPLAY= \
    IS_SANDBOX=1 \
    GIT_CONFIG_GLOBAL=/etc/claude-gitconfig \
    GIT_CONFIG_SYSTEM=/dev/null \
    claude --allow-dangerously-skip-permissions --permission-mode auto
