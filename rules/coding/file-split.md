# File Split Rule

Keep all prompt and code files compact. Split at the thresholds below.

## Pattern A — Code files

- WARN: >300 lines. HARD (must split): >500 lines.
- Keep `<name>.<ext>` as a dispatch + re-export shim; place logic in a sibling `<name>/` folder.
- Shared utilities across hooks: `hooks/lib/`; otherwise adjacent `lib/`.

## Pattern B — SKILL.md

- WARN: >100 lines. HARD (must split): >200 lines.
- Keep `SKILL.md` as the prompt entrypoint; do not shim it.
- Extract procedures (3+ steps) to `skills/<name>/scripts/<verb>.sh` or `bin/<tool>`.
