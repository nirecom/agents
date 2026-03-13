# Coding Guidelines

## Public GitHub Rules

- Never commit private information (automatically enforced by pre-commit hook and Claude Code PreToolUse hook — see `docs/private-info-scanning.md` for the full list of detected patterns). Use generic placeholders or descriptions instead.
- Always add `.env` to `.gitignore` to exclude secrets from version control.
- Source code and config file messages/comments must be in English.
- Do NOT add `Co-Authored-By` trailers to commit messages.
