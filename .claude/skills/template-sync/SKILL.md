---
name: template-sync
description: Activate when editing files in the meta repo (root) that have a counterpart under template/, or vice versa. Asks the user whether to mirror the change before continuing.
---

# Template ↔ meta-repo sync

This repo is a Copier template that dogfoods its own output: most
Claude / devcontainer / justfile assets exist twice — once at the repo
root (the meta repo) and once under `template/` (rendered into user
projects). Changes in one side often need to be mirrored in the other,
but not always.

Before editing either side, check whether a counterpart exists. If it
does, **ask the user before continuing**:

> "I'm about to change X in the meta repo. The template has a counterpart
> at Y. Should I mirror the change?" — and the equivalent in reverse.

Default to mirroring unless the user declines.

## Known pairs

| Meta repo                            | Template                                                                     | Linked? |
| ------------------------------------ | ---------------------------------------------------------------------------- | ------- |
| `justfile`                           | `template/{% if add_claude %}justfile{% endif %}.jinja`                      | no (jinja escape on `glab-auth` parameter) |
| `.devcontainer/claude-sandbox.sh`    | `template/.devcontainer/{% if add_claude %}claude-sandbox.sh{% endif %}`     | symlink |
| `README-CLAUDE.md`                   | `template/{% if add_claude %}README-CLAUDE.md{% endif %}.jinja`              | symlink |
| `CLAUDE.md`                          | `template/{% if add_claude %}CLAUDE.md{% endif %}.jinja`                     | symlink |
| `.claude/commands/<name>.md`         | `template/{% if add_claude %}.claude{% endif %}/commands/<name>.md`          | symlink |

The list can drift; use `find template/` to discover other counterparts.

## Prefer symlinks for deduplication

Where the template body has no jinja content (no `{% ... %}` and no
`{{ ... }}`), make the template path a symlink into the meta repo
rather than a duplicate file. Copier resolves the symlink at render
time and writes a regular file into the user's project, so end users
never see the link. This makes drift impossible by construction —
`grep -nE '\{[%{].*[%}]\}' <template-file>` should return nothing
before you symlink. Existing examples: `.pre-commit-config.yaml`,
`.python-version`, `.gitleaks.toml`, the `.github/workflows/*.yml`
files, and the Claude assets above.

## Don't mirror

- Meta-repo-only: `copier.yml`, `tests/`, root `pyproject.toml`, CI for
  the template itself, `.claude/commands/verify-sandbox.md` (the
  sandbox verifier is for hardening this repo, not user projects).
- Template-only: jinja conditionals (`{% ... %}`) and copier variable
  references (`{{ ... }}`). When the meta side has a literal `{{ x }}`
  (e.g. a justfile parameter), the template side escapes it as
  `{{ '{{' }} x {{ '}}' }}` so Copier renders back to the meta form.

The hardened sandbox (`unshare -m -p -i --fork --mount-proc --kill-child`,
capability stripping, `/etc/gitconfig` mask) is **not** an intentional
divergence — both sides ship it. A user-project running `just claude`
without the `/etc/gitconfig` mask hits the VS Code dev-container
`credential.helper` path and fails.

## CI enforcement

Two tests in `tests/test_example.py` enforce parity for files that
matter — drift fails CI:

- `test_gitignore_same` — `.gitignore` must equal `template/.gitignore`
  byte-for-byte.
- `test_meta_matches_template` — what the template renders with the
  meta repo's options (`add_claude=True, docker=False`) must equal the
  meta repo for: `.devcontainer/devcontainer.json`,
  `.devcontainer/initializeCommand.sh`, `.devcontainer/claude-sandbox.sh`,
  `Dockerfile`, `justfile`, `CLAUDE.md`, `README-CLAUDE.md`, and
  `.claude/commands/*.md`.

If you change one side of a pair these tests cover, mirror to the other
side or expect CI to fail. The render command for the second test is
`copy_project(tmp_path, add_claude=True, docker=False, docker_debug=False)`
in `tests/test_example.py`.
