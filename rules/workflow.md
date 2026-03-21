# Workflow

## Verification Before Proceeding

When the user asks you to verify or test something, complete it and report results
BEFORE moving to the next task. Never skip or assume success.

## File Edits

- **CLI（ターミナル）使用時のみ**: Edit 実行前にチャットで diff を提示し、ユーザーの承認後に Edit を実行する。VSCode 使用時は内蔵の diff ダイアログに任せるため不要。

## Cross-Platform Orthogonality

- When adding or modifying functionality for one platform (e.g., `install/win/`), apply the equivalent change to other platforms (e.g., `install/linux/`) unless there is a platform-specific reason not to.
