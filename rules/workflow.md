# Workflow

## Testing

Before modifying any source code, first create or update test scripts:
- Use the project's existing test directory if one exists; otherwise create `tests/`.
- Tests must cover both normal and abnormal cases.
- Run all relevant tests and confirm they pass before committing.

### Test File Naming

Name test files after the branch they belong to, replacing `/` with `-`:

```
tests/<branch-type>-<branch-name>.<ext>
```

- `feature/claude-rules` → `tests/feature-claude-rules.sh`
- `fix/ssh-keys` → `tests/fix-ssh-keys.sh`
- main direct work: `tests/main-<name>.sh`
- Multiple files per feature: add a suffix (e.g., `feature-claude-rules-global.sh`)

| Language | Extension |
|---|---|
| bash | `.sh` |
| PowerShell (Pester) | `.Tests.ps1` |

## Verification Before Proceeding

When the user asks you to verify or test something, complete it and report results
BEFORE moving to the next task. Never skip or assume success.

## File Edits

- Always show a diff before applying file edits. Do not apply edits without showing the diff first.

## Cross-Platform Orthogonality

- When adding or modifying functionality for one platform (e.g., `install/win/`), apply the equivalent change to other platforms (e.g., `install/linux/`) unless there is a platform-specific reason not to.
