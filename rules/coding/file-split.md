# File Split Rule

Split any file that exceeds its HARD limit. Pattern depends on file type.

## Pattern A — Code files (>500 lines)

- Keep `<name>.<ext>` as a dispatch + re-export shim only; no logic inside.
- Create a sibling `<name>/` folder; place domain-named modules there.
- Shared utilities across hooks: `hooks/lib/`; otherwise adjacent `lib/`.
- Example: `hooks/enforce-worktree.js` + `hooks/enforce-worktree/`.

## Pattern B — SKILL.md (>200 lines)

- Keep `SKILL.md` as the prompt entrypoint; do not shim it.
- Extract procedures (3+ steps) to `skills/<name>/scripts/<verb>.sh` or `bin/<tool>`.
- Replace the inline procedure with a one-line CLI reference in SKILL.md.
- Do not use `skills/<name>/lib/` — SKILL.md is a prompt file, not a code module.
