#!/bin/bash
# Inner script for `just claude`: runs inside private mount, PID, and
# IPC namespaces (created by `unshare -m -p -i --fork --mount-proc` in
# the justfile recipe). Tmpfs-masks the directories VS Code uses for
# host bridges, writes a Claude-only /etc/claude-gitconfig, and exec's
# claude with GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM pointed away from the
# host gitconfigs — plus PR_SET_PDEATHSIG (so claude dies if the
# wrapping shell does), an empty capability bounding set, and
# PR_SET_NO_NEW_PRIVS (so Claude runs with CapEff=0 and cannot regain
# caps via setuid binaries or file caps). The git redirection is via
# env vars rather than file-bind mounts because file-bind mounts on
# /etc/gitconfig and /root/.gitconfig are silently invalidated by
# atomic-rename rewrites from VS Code's dev.containers.copyGitConfig
# on every reconnect — see README-CLAUDE.md for the full reasoning.
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
# .netrc is a single file, not a dir — mask via bind to /dev/null.
if [ -e /root/.netrc ]; then
    mount --bind /dev/null /root/.netrc
fi

# Build a Claude-only gitconfig at /etc/claude-gitconfig containing the
# in-container credential helpers (gh / glab) and HTTPS rewrites — and
# nothing else the user has on the host (no SSH url rewrites, no
# host-specific helpers). User identity is read from the original
# gitconfig BEFORE the env redirection takes effect on the exec line,
# so commits Claude makes are still attributed. Hardcode the gh/glab
# paths — `command -v` could resolve to a `.vscode-server`-pathed
# binary in some setups and embed that string into our helper line,
# which would later trip the sandbox-check hook on what looks like a
# VS Code credential bridge.
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
# No mount --bind on /etc/gitconfig or /root/.gitconfig: VS Code's
# dev.containers.copyGitConfig atomically rewrites /root/.gitconfig
# (write-tmp + rename) on every reconnect, which replaces the dentry
# our bind would attach to and silently invalidates the bind. Same
# fragility applies to any file-bind whose target is on the shared
# overlay filesystem. Instead we redirect git via GIT_CONFIG_GLOBAL
# and GIT_CONFIG_SYSTEM env vars on the exec line — process env on
# Claude's tree, not in the mount table, so it cannot be invalidated
# by file-level operations in the parent. Tools that ignore those
# env vars and read /root/.gitconfig directly will see host content,
# but every credential bridge that content references (VS Code git
# helper script, SSH agent socket, askpass) lives in /tmp or under
# /run/user — both tmpfs-masked above — so reading the path doesn't
# yield reachable credentials.

# IS_SANDBOX=1 is the canary `.claude/hooks/sandbox-check.sh` keys off.
# Env-blanks: SSH_AUTH_SOCK / VSCODE_GIT_IPC_HANDLE / VSCODE_IPC_HOOK_CLI
# all point into /tmp (already tmpfs in this namespace), but blanking
# the vars stops Claude from even *trying* the path. GIT_ASKPASS and
# VSCODE_GIT_ASKPASS_* point under /.vscode-server which the namespace
# does NOT mask — blanking them is the actual defence against Claude
# triggering the VS Code "log in to GitHub" popup. BROWSER points at a
# host helper that opens URLs in the user's browser — blanked so
# Claude cannot drive the user's browser.
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
    IS_SANDBOX=1 \
    GIT_CONFIG_GLOBAL=/etc/claude-gitconfig \
    GIT_CONFIG_SYSTEM=/dev/null \
    claude --allow-dangerously-skip-permissions --permission-mode auto
