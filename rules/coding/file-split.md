# File Split Rule

Keep all prompt and code files compact. Split when any size limit is exceeded — HARD or WARN.

## Pattern A — Code files

- Keep `<name>.<ext>` as a dispatch + re-export shim; place logic in a sibling `<name>/` folder.
- Shared utilities across hooks: `hooks/lib/`; otherwise adjacent `lib/`.

## Pattern B — SKILL.md

- Keep `SKILL.md` as the prompt entrypoint; do not shim it.
- Extract procedures (3+ steps) to `skills/<name>/scripts/<verb>.sh` or `bin/<tool>`.
