# Git Commands

## Commands for Other Directories

When running git commands outside the current working directory, always use
`git -C <path>` instead of `cd <path> && git ...`.

CORRECT: `git -C /path/to/repo log --oneline -5`
WRONG:   `cd /path/to/repo && git log --oneline -5`

## Write Commands

When running `git add`, `git commit`, and `git push`, always run them as **separate sequential Bash calls** — do NOT chain them with `&&`.

CORRECT (separate calls):
1. `git add file1 file2`
2. `git commit -m "message"`
3. `git push`

WRONG (chained): `git add file1 && git commit -m "msg" && git push`

This ensures each command matches its individual permission rule in `settings.json`.
