---
paths:
  - ".on-demand-only/never-match"
---
<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->

# Coding Guidelines

## Public GitHub Rules

- Never commit private information (automatically enforced by pre-commit hook and Claude Code PreToolUse hook — see `docs/scan-outbound.md` for the full list of detected patterns). Use generic placeholders or descriptions instead.
  - Fictional email addresses for tests must use the `example.com` domain (RFC 2606 reserved).
- Before writing machine-specific information to any public file, check `.private-info-blocklist` in the repo root for forbidden patterns. Skip silently if the file does not exist.
- Always add `.env` to `.gitignore` to exclude secrets from version control.
- Do NOT add `Co-Authored-By` trailers to commit messages.
- Always choose the simplest implementation.

## Comments

- Resolve the limit before the first comment: `bash "$AGENTS_CONFIG_DIR/bin/get-config-var" COMMENT_BLOCK_MAX_LINES 10` — the printed value is a HARD limit no comment block may exceed, for any reason.
- Fitting under the limit is not permission to reach it: write no comment by default, and add one only where a rule below grants it.
- File header: the comment block a reader needs before reading the file may be written there.
- Mid-file: write a comment **only when the intent is undecipherable without it**, in 1–2 lines.

## Migration Code Blocks

Temporary migration code must be wrapped with `# --- BEGIN temporary: <old> → <new> migration ---` / `# --- END temporary: ... ---` markers.

- Description format: `<old path/name> → <new path/name> migration`
- Grep-friendly: `grep -r "BEGIN temporary"` finds all migration blocks for cleanup

See also `rules/installer.md` for installer and system configuration rules.

## bin/ Script Execute Bit

When adding a new script (`.sh` or shebang-based extensionless file) under `bin/`, immediately run:

    git update-index --chmod=+x <path>

This records mode 100755 in the git index regardless of `core.fileMode` setting, ensuring the execute bit is preserved on all platforms (macOS, Linux, WSL).

## File Naming Conventions

- **Backup files:** Use `.bak` extension. Overwrite previous `.bak` (do not accumulate). Timestamped variants (`.bak.YYYYMMDD_HHMMSS`) are acceptable when history preservation is needed.

See also `rules/core-principles.md` for the top-level design principles.

## Sub-rules (loaded conditionally via the `paths:` frontmatter key)

Each sub-rule carries its own `paths:` globs, so it is still injected on a file match independently of this hub — de-injecting the hub does not de-inject them.

- [coding/python.md](coding/python.md) — `uv` mandatory; bare `python`/`pip` prohibited
- [coding/nodejs.md](coding/nodejs.md) — `fnm` (Windows) / `nvm` (POSIX) mandatory
- [coding/file-split.md](coding/file-split.md) — HARD limit file split: code → `<name>/` sibling folder; SKILL.md → `scripts/` or `bin/`
