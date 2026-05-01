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

| Meta repo                            | Template                                                                     |
| ------------------------------------ | ---------------------------------------------------------------------------- |
| `justfile`                           | `template/{% if add_claude %}justfile{% endif %}.jinja`                      |
| `.devcontainer/claude-sandbox.sh`    | `template/.devcontainer/{% if add_claude %}claude-sandbox.sh{% endif %}`     |
| `README-CLAUDE.md`                   | `template/{% if add_claude %}README-CLAUDE.md{% endif %}.jinja`              |
| `CLAUDE.md`                          | `template/{% if add_claude %}CLAUDE.md{% endif %}.jinja`                     |
| `.claude/commands/<name>.md`         | `template/{% if add_claude %}.claude{% endif %}/commands/<name>.md`          |

The list can drift; use `find template/` to discover other counterparts.

## Don't mirror

- Meta-repo-only: `copier.yml`, `tests/`, root `pyproject.toml`, CI for
  the template itself.
- Template-only: jinja conditionals (`{% ... %}`) and copier variable
  references (`{{ ... }}`).
- Intentional divergences: e.g. the meta repo's `justfile` uses
  `unshare -m -p -i --fork --mount-proc --kill-child`, while the
  template's uses just `unshare -m`. If the user has chosen to harden
  one side and not the other, do not "fix" the divergence without
  asking.
