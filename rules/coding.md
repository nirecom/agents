# Coding Guidelines

## Public GitHub Rules

- Never commit private information (automatically enforced by pre-commit hook and Claude Code PreToolUse hook — see `docs/scan-outbound.md` for the full list of detected patterns). Use generic placeholders or descriptions instead.
  - Fictional email addresses for tests must use the `example.com` domain (RFC 2606 reserved).
- Before writing machine-specific information to any public file, check `.private-info-blocklist` in the repo root for forbidden patterns. Skip silently if the file does not exist.
- Always add `.env` to `.gitignore` to exclude secrets from version control.
- Do NOT add `Co-Authored-By` trailers to commit messages.

## Migration Code Blocks

Temporary migration code must be wrapped with `BEGIN/END temporary` markers:

```
# --- BEGIN temporary: <old> → <new> migration ---
...migration logic...
# --- END temporary: <old> → <new> migration ---
```

- Description format: `<old path/name> → <new path/name> migration`
- Grep-friendly: `grep -r "BEGIN temporary"` finds all migration blocks for cleanup

See also `rules/installer.md` for installer and system configuration rules.

## File Naming Conventions

- **Backup files:** Use `.bak` extension. Overwrite previous `.bak` (do not accumulate). Timestamped variants (`.bak.YYYYMMDD_HHMMSS`) are acceptable when history preservation is needed.

See also `rules/core-principles.md` for the top-level design principles.

## Sub-rules (path-scoped via `globs:`)

- [coding/python.md](coding/python.md) — `uv` 使用必須、bare `python`/`pip` 禁止
- [coding/nodejs.md](coding/nodejs.md) — `fnm`(Windows) / `nvm`(POSIX) 使用必須
