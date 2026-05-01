#!/bin/bash
set -euo pipefail

# Create host-side dirs needed for bind mounts before the container starts.
# `terminal-config` holds shell config shared across every devcontainer; the
# nested `.claude` is Claude's config shared across every devcontainer built
# from this template (symlink ~/.claude into it for host sync).
mkdir -p "$HOME/.config/terminal-config/.claude"
