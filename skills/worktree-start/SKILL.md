---
name: worktree-start
description: Set up a git worktree for a parallel-session task and copy required gitignored state
---

Set up a new linked worktree and initialize its gitignored state before starting work.

**Personal config:** Set `WORKTREE_BASE_DIR` in your agents config to customize the worktree
base path. Default: `~/git/worktrees`. Windows example: `WORKTREE_BASE_DIR=C:\git\worktrees`.

## Procedure

1. Verify the task fits the worktree criteria in `rules/worktree.md` (fit table).
   If it does not fit, report why and stop — set `ENFORCE_WORKTREE=off` in agents config
   and work on main directly instead.

2. Estimate the task name from the user's message. Task names must match `[a-zA-Z0-9_-]+`
   (no slashes, dots, spaces, or shell metacharacters).
   Estimate the branch type: `feature` / `fix` / `refactor` / `docs` / `chore`.
   Ask the user to confirm both (or suggest corrections) with `AskUserQuestion`.

3. Compute the canonical worktree path and show it to the user for final confirmation:
   ```
   <WORKTREE_BASE_DIR>/<task-name>/<repo-name>
   ```
   Branch name: `<type>/<task-name>`

4. Check for conflicts:
   ```
   git worktree list --porcelain
   ```
   Report any existing worktrees at the same path or on the same branch.

5. Create the parent directory (platform-aware):
   - POSIX: `mkdir -p "<WORKTREE_BASE_DIR>/<task-name>"`
   - PowerShell: `New-Item -ItemType Directory -Force -Path "<WORKTREE_BASE_DIR>\<task-name>"`

6. Create the worktree:
   ```
   git worktree add <path> -b <type>/<task-name>
   ```

7. Enumerate gitignored and untracked files in main (NUL-delimited for paths with spaces
   and non-ASCII characters):
   ```
   git -C <main> ls-files --others --ignored --exclude-standard -z
   git -C <main> ls-files --others --exclude-standard -z
   ```

8. Classify the results and present to the user:
   - **Copy recommended:** `.env.local`, `.env.development`, dev credentials, development configs
   - **Copy prohibited:** `.env.production`, cloud credentials, deploy keys, prod tokens,
     customer data access keys
   - **Alternative recommended:** Create new dev credentials for the worktree using `.env.example`
     as a base. Present the generation command (e.g., `/create-key`) —
     the user must create and fill in the actual `.env` file. Claude must not write to `.env`
     directly.

9. Determine copy mode via Bash:
     `bash -c 'get-config-var --is-off CONFIRM_WORKTREE on && echo OFF || echo ON'`
   - stdout `OFF`: copy all "Copy recommended" entries automatically. Never copy "Copy prohibited" (production secrets, deploy keys, cloud credentials). Never write `.env` directly. Print the resulting copy log inline. Do NOT call `AskUserQuestion`.
   - stdout `ON`: present candidates via `AskUserQuestion` as today (existing behavior).

10. Create `WORKTREE_NOTES.md` in the worktree root recording:
    - Resolved worktree path and the `WORKTREE_BASE_DIR` value used
    - Branch name and creation date
    - Gitignored files copied from main
    ```
    # Worktree Notes
    Branch: <type>/<task-name>
    Created: <date>
    Path: <resolved-path>
    WORKTREE_BASE_DIR: <value or "(default)">

    ## Gitignored files copied from main
    - <file1>
    - <file2>
    ```
    Add `WORKTREE_NOTES.md` to `.git/info/exclude` if not already covered by `.gitignore`.

11. Final report: worktree path, branch, and which gitignored state was copied.

## Rules

- Never write to `.env` files directly.
- Never copy production secrets (`.env.production`, cloud credentials, deploy keys) to a worktree.
- Always record copied state in `WORKTREE_NOTES.md` so `/worktree-end` can inventory it later.
- Task name validation: reject names that fail `[a-zA-Z0-9_-]+` — do not proceed with invalid names.
