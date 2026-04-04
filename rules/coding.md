# Coding Guidelines

## Public GitHub Rules

- Never commit private information (automatically enforced by pre-commit hook and Claude Code PreToolUse hook — see `docs/private-info-scanning.md` for the full list of detected patterns). Use generic placeholders or descriptions instead.
  - Fictional email addresses for tests must use the `example.com` domain (RFC 2606 reserved).
- Always add `.env` to `.gitignore` to exclude secrets from version control.
- Source code and config file messages/comments must be in English.
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

## Installer & System Configuration Principles

- **System stability is the top priority.** Do not pollute the registry with unverified entries.
- **Do not force external configuration** — even if the user requests it:
  - Registry-based flag injection must be verified to actually work before writing. If the app ignores externally written entries (e.g., encrypted config, internal state mismatch), abandon the approach rather than leave dead entries.
  - Never patch binary or encrypted config files to inject settings. (Precedent: Google Japanese Input config.)
- **Clean up mistakes immediately.** If a registry entry turns out to be ineffective, delete it before proceeding with any other fix.

## Python

- Do not use bare `python`, `pip`, or `python3` commands. Always use `uv` (`uv run`, `uv pip`, etc.).
- For one-off scripts: `uv run script.py`
- For adding dependencies: `uv pip install` or `uv add`

## Node.js

- Do not install Node.js directly. Use a version manager:
  - **Windows (PowerShell):** `fnm` (`fnm use` / `.node-version` auto-detection)
  - **WSL2 / macOS / Linux:** `nvm` (`nvm use` / `.nvmrc` auto-detection)

## File Naming Conventions

- **Backup files:** Use `.bak` extension. Overwrite previous `.bak` (do not accumulate). Timestamped variants (`.bak.YYYYMMDD_HHMMSS`) are acceptable when history preservation is needed.

See also `rules/orthogonality.md` for cross-platform and naming consistency rules.
