# Start Claude Code in sandbox mode (no SSH agent, auto permission mode).
# Runs Claude inside private mount, PID, AND IPC namespaces so VS Code's
# host-bridge sockets (vscode-ipc-*.sock, vscode-git-*.sock,
# vscode-ssh-auth-*.sock, vscode-remote-containers-ipc-*.sock) in /tmp
# and /run/user/<uid>/ are invisible — Claude sees empty tmpfs at those
# paths. The PID namespace (-p --fork --mount-proc) hides outer
# processes so /proc/1/root cannot be used to dereference the parent
# mount namespace and reach those sockets via the unmasked host /tmp.
# The IPC namespace (-i) prevents Claude from reading host SysV shared
# memory / message queues should the host ever start using them.
# --kill-child propagates the wrapping shell's death down to Claude;
# setpriv --pdeathsig SIGKILL inside the inner script is the
# belt-and-braces backup. See README-CLAUDE.md for the full sandbox model.
claude:
    exec unshare -m -p -i --fork --mount-proc --propagation private --kill-child bash .devcontainer/claude-sandbox.sh


# Authenticate gh CLI with a GitHub PAT (token not stored in shell history)
gh-auth:
    #!/bin/bash
    cat <<'EOF'
    Create or renew a fine-grained PAT at:
      https://github.com/settings/personal-access-tokens

    Recommended settings for a sandboxed Claude Code:
      - Resource owner: your user (or org that owns this repo)
      - Repository access: Only select repositories -> just this repo
      - Expiration: short (e.g. 30 days) so a leaked token expires quickly
      - Repository permissions (Read and Write):
          Contents, Issues, Pull requests
        (Metadata: Read-only is added automatically)
      - Leave everything else unset / no access

    EOF
    read -sp "GitHub PAT: " t && echo
    echo "$t" | gh auth login --with-token
    unset t
    gh auth setup-git
    gh auth status


# Authenticate glab CLI with a GitLab PAT (token not stored in shell history).
# --git-protocol https prevents glab's SSH insteadOf rewrite.
glab-auth hostname="gitlab.com":
    #!/bin/bash
    read -sp "GitLab PAT for {{ hostname }}: " t && echo
    echo "$t" | glab auth login --stdin --hostname {{ hostname }} --git-protocol https
    unset t
    glab auth status
