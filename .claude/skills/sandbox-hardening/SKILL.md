---
name: sandbox-hardening
description: Activate when editing claude-sandbox.sh, the sandbox-check hook, the unshare flags in the justfile claude recipe, or the threat-model section of README-CLAUDE.md. Encodes hard-won lessons about which sandbox primitives are actually robust under VS Code's runtime behaviour.
---

# Claude sandbox hardening — gotchas

## File-bind mounts are fragile under atomic-rename in the parent

`mount --bind <source-file> <target-file>` on a path that lives on the
container's shared overlay filesystem is silently invalidated when
anything in the parent namespace rewrites the target via
`write-tmp + rename(2)` (the standard "atomic write" pattern).
Mechanism: `rename(2)` replaces the dentry the bind was hooked onto;
the mount-table entry orphans and path lookup goes through the new
dentry, bypassing the mount.

This happens for `/root/.gitconfig` on every VS Code reconnect
because `dev.containers.copyGitConfig` re-copies the host gitconfig
atomically. It also happens for `/etc/gitconfig` whenever the system
config is rewritten. **`--propagation private` does not defend
against this** — it blocks mount-event propagation, not file-level
operations on bind targets.

Symptom: `mount --bind` succeeds at script time (`set -e` doesn't
trip), Claude works for several prompts, then the hook fires
mid-session reporting that the bind has dropped. `mountinfo` confirms
no entry for the bind target. No `umount` happened.

Tmpfs-over-a-directory mounts (`/tmp`, `/root/.ssh`, `/run/user`) are
**not** affected by this — directory dentries don't get atomically
replaced by routine VS Code behaviour.

## Robust alternatives

For things git-related, prefer `GIT_CONFIG_GLOBAL=/path/to/curated`
and `GIT_CONFIG_SYSTEM=/dev/null` set in the `setpriv` exec env.
Process env on Claude's tree — not in the mount table, not
invalidated by file-level ops. The `/root/.gitconfig` and
`/etc/gitconfig` paths still show host content if read directly, but
git reads from the env-var-named path, and every credential bridge
the host content references (VS Code git helper, SSH agent,
askpass) lives in `/tmp` / `/run/user` which **are** tmpfs-masked.

## Threat model is not absolute

`unshare --propagation private` does NOT make the sandbox
inviolable. A `CAP_SYS_ADMIN`-bearing actor in the parent userns can
`setns(2)` into Claude's mount namespace and `umount` anything.
Routine VS Code behaviour doesn't do this — but the mount layer
should be treated as defence-in-depth on top of env-var-based
redirection wherever both are available, not as the sole barrier.

## Hook design

`.claude/hooks/sandbox-check.sh` should verify mount-table integrity
explicitly via `findmnt -no FSTYPE <path>` rather than only checking
env vars and file content. Conditional checks for any directory
`claude-sandbox.sh` would have masked (mirroring its own `if [ -d
... ]` logic) catch the case where a tmpfs that *should* be there
silently dropped.

## Avoid `command -v` for paths that land in `/etc/claude-gitconfig`

`command -v gh` / `command -v glab` can resolve to a binary under
`/.vscode-server/...` if the Dev Containers extension installs
tooling there and prepends to PATH. Embedding that path string in a
credential-helper line then trips a hook that greps the file for
`vscode-server`/`vscode-remote-containers`. Hardcode `/usr/bin/gh`
and `/usr/local/bin/glab` (matching the Dockerfile's install
locations).

## Don't use copier `_tasks`

`_tasks` requires the user to pass `--trust` to copier when running
`copy` / `update`. Avoid them — solve the problem inside script
content (e.g. invoke `bash <script>` instead of relying on the exec
bit being preserved through symlink resolution).
