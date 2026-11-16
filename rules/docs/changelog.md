---
paths:
  - "CHANGELOG.md"
  - "docs/CHANGELOG.md"
---

## CHANGELOG.md Rules

User-facing release log. Write only changes the user feels:
- A serious bug got fixed, or this fix introduced a new known issue.
- Behaviour changes — workflow steps, command outputs, default behaviour.
- Configuration changes — new env vars, renamed/removed options, breaking format changes.

Do NOT include internal function / module / hook names — those belong in `history.md`.
Written by `/update-docs` via `doc-append CHANGELOG.md` (no `--commits`).
Rotation archives old entries to `docs/changelog/<year>.md`; a retired `changelog/` dir beside a root `CHANGELOG.md` is moved there by the next local `doc-rotate.py` run.

Under `ENFORCE_WORKTREE=on`, `/update-docs` stages user-facing bullets (public repos only) into `WORKTREE_NOTES.md` `## Changelog Notes`. `bin/compose-doc-append-entry` appends them to `CHANGELOG.md` during `/worktree-end` Step WE-17.
