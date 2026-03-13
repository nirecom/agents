# Global Claude Code Instructions

## Coding Guidelines

### Public GitHub Rules

- Never commit private information (automatically enforced by pre-commit hook and Claude Code PreToolUse hook — see `docs/private-info-scanning.md` for the full list of detected patterns). Use generic placeholders or descriptions instead.
- Always add `.env` to `.gitignore` to exclude secrets from version control.
- Source code and config file messages/comments must be in English.
- Do NOT add `Co-Authored-By` trailers to commit messages.

## Workflow Preferences

### Shell Commands

When providing shell commands (curl, docker, etc.):
- Always write commands on a single line — do NOT use backslash `\` line continuation

**curl commands MUST follow all three rules (PowerShell compatibility):**
1. Use `curl.exe` — NEVER bare `curl` (PowerShell aliases it to `Invoke-WebRequest`)
2. Use single quotes for JSON body — NEVER escaped double quotes:
   CORRECT: `curl.exe -d '{"key":"value"}'`
   WRONG:   `curl -d "{\"key\":\"value\"}"`
3. No line continuation — single line only

### Git Commands for Other Directories

When running git commands outside the current working directory, always use
`git -C <path>` instead of `cd <path> && git ...`.

CORRECT: `git -C /path/to/repo log --oneline -5`
WRONG:   `cd /path/to/repo && git log --oneline -5`

### Git Write Commands

When running `git add`, `git commit`, and `git push`, always run them as **separate sequential Bash calls** — do NOT chain them with `&&`.

CORRECT (separate calls):
1. `git add file1 file2`
2. `git commit -m "message"`
3. `git push`

WRONG (chained): `git add file1 && git commit -m "msg" && git push`

This ensures each command matches its individual permission rule in `settings.json`.

### Testing

Before modifying any source code, first create or update test scripts:
- Use the project's existing test directory if one exists; otherwise create `tests/`.
- Tests must cover both normal and abnormal cases.
- Run all relevant tests and confirm they pass before committing.

### Verification Before Proceeding

When the user asks you to verify or test something, complete it and report results
BEFORE moving to the next task. Never skip or assume success.

### File Edits

- Always show a diff before applying file edits. Do not apply edits without showing the diff first.

### Cross-Platform Orthogonality

- When adding or modifying functionality for one platform (e.g., `install/win/`), apply the equivalent change to other platforms (e.g., `install/linux/`) unless there is a platform-specific reason not to.

## Private task instructions

Work instructions received from Claude.ai or other external sources that contain private information must be saved under
`.context-private/`, not in `CLAUDE.md` or `context/`.
