# Workflow

## Testing

Before modifying any source code, first create or update test scripts:
- Use the project's existing test directory if one exists; otherwise create `tests/`.
- Tests must cover both normal and abnormal cases.
- Run all relevant tests and confirm they pass before committing.

## Verification Before Proceeding

When the user asks you to verify or test something, complete it and report results
BEFORE moving to the next task. Never skip or assume success.

## File Edits

- Always show a diff before applying file edits. Do not apply edits without showing the diff first.

## Cross-Platform Orthogonality

- When adding or modifying functionality for one platform (e.g., `install/win/`), apply the equivalent change to other platforms (e.g., `install/linux/`) unless there is a platform-specific reason not to.
