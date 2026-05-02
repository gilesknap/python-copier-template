#!/bin/bash
# UserPromptSubmit hook: verify the Claude sandbox is intact before
# executing any prompt. Exit code 2 blocks the prompt and shows the
# message to the user. See README-CLAUDE.md for the full sandbox model.

fail() { echo "BLOCKED: $1" >&2; exit 2; }

# Are we in the devcontainer at all?
[ -n "${IN_DEVCONTAINER:-}" ] || \
    fail "not in the devcontainer (IN_DEVCONTAINER unset). Reopen the project in the devcontainer."

# IS_SANDBOX=1 is set by claude-sandbox.sh's exec line. If it's missing,
# Claude was launched without the namespace and the host bridges in /tmp
# are reachable.
[ -n "${IS_SANDBOX:-}" ] || \
    fail "IS_SANDBOX unset — Claude was not launched via \"just claude\", so the mount-namespace sandbox is not active."

# Host SSH agent must not be reachable. remoteEnv blanks SSH_AUTH_SOCK and
# `just claude` re-blanks it; if it is set, neither layer applied.
[ -z "${SSH_AUTH_SOCK:-}" ] || \
    fail "SSH_AUTH_SOCK is set ($SSH_AUTH_SOCK) — host SSH agent is reachable. Exit Claude and re-run \"just claude\"."

# GIT_ASKPASS points at a script under /.vscode-server, which the
# namespace does NOT mask. If the env var is non-empty AND the file is
# reachable, claude-sandbox.sh's exec-line blank failed to apply.
[ ! -e "${GIT_ASKPASS:-}" ] || \
    fail "GIT_ASKPASS script ($GIT_ASKPASS) is reachable — claude-sandbox.sh did not blank the env var. Rebuild the devcontainer or re-run \"just claude\"."

# Git config redirection. claude-sandbox.sh's exec sets GIT_CONFIG_GLOBAL
# to the curated /etc/claude-gitconfig and GIT_CONFIG_SYSTEM to /dev/null
# so git ignores both /root/.gitconfig (host content) and /etc/gitconfig
# (system credential helper) without relying on file-bind mounts that
# atomic-rename rewrites silently invalidate.
[ "${GIT_CONFIG_GLOBAL:-}" = "/etc/claude-gitconfig" ] || \
    fail "GIT_CONFIG_GLOBAL is '${GIT_CONFIG_GLOBAL:-<unset>}', not /etc/claude-gitconfig — git would fall back to host-injected /root/.gitconfig. Exit Claude and re-run \"just claude\"."
[ "${GIT_CONFIG_SYSTEM:-}" = "/dev/null" ] || \
    fail "GIT_CONFIG_SYSTEM is '${GIT_CONFIG_SYSTEM:-<unset>}', not /dev/null — git would read the host /etc/gitconfig. Exit Claude and re-run \"just claude\"."

# /etc/claude-gitconfig must hold only the curated gh/glab helpers; if it
# names /.vscode-server or vscode-remote-containers something has rewritten
# our config.
! grep -q -e 'vscode-remote-containers' -e '\.vscode-server' /etc/claude-gitconfig 2>/dev/null || \
    fail "/etc/claude-gitconfig contains a VS Code credential bridge — the curated config was overwritten. Exit Claude and re-run \"just claude\"."

# Mount integrity: tmpfs masks for the directories VS Code populates with
# host bridge sockets, plus any host credential dir bind-mounted into the
# container. /tmp is unconditional; the others mirror claude-sandbox.sh's
# own conditional logic — only check the tmpfs if the directory exists.
require_tmpfs() {
    local p="$1"
    [ "$(findmnt -no FSTYPE "$p" 2>/dev/null)" = "tmpfs" ] || \
        fail "$p is not tmpfs in Claude's namespace — host bridges/credentials at $p are reachable. Exit Claude and re-run \"just claude\"."
}
require_tmpfs /tmp
[ ! -d /run/user ] || require_tmpfs /run/user
for d in /root/.ssh /root/.gnupg /root/.aws /root/.azure /root/.gcloud /root/.docker; do
    [ ! -d "$d" ] || require_tmpfs "$d"
done

exit 0
