---
name: worktree-start
description: Set up a git worktree and safely copy required gitignored files from main
---

Set up a new worktree and initialize its gitignored state before starting work.

## Procedure

1. Verify the task fits the worktree criteria in `rules/worktree.md` (fit table).
   If it does not fit, report why and stop — work on main directly instead.

2. Confirm the worktree path and branch name with the user.

3. Check for conflicts:
   ```
   git worktree list --porcelain
   ```
   Report any existing worktrees at the same path or on the same branch.

4. Create the worktree:
   ```
   git worktree add <path> -b <branch>
   ```

5. Enumerate gitignored and untracked files in main (NUL-delimited for paths with spaces
   and non-ASCII characters):
   ```
   git -C <main> ls-files --others --ignored --exclude-standard -z
   git -C <main> ls-files --others --exclude-standard -z
   ```

6. Classify the results and present to the user:
   - **Copy recommended:** `.env.local`, `.env.development`, dev credentials, development configs
   - **Copy prohibited:** `.env.production`, cloud credentials, deploy keys, prod tokens,
     customer data access keys
   - **Alternative recommended:** Create new dev credentials for the worktree using `.env.example`
     as a base. Present the generation command (e.g., `openssl rand -hex 32`) —
     the user must create and fill in the actual `.env` file. Claude must not write to `.env`
     directly.

7. Copy files per user instruction (candidates are presented automatically; user approval required).

8. Create `WORKTREE_NOTES.md` in the worktree root (add to `.git/info/exclude` if not already
   covered by `.gitignore`) recording which gitignored files were copied:
   ```
   # Worktree Notes
   Branch: <branch>
   Created: <date>

   ## Gitignored files copied from main
   - <file1>
   - <file2>
   ```

9. Report: which worktree contains which gitignored state.

## Rules

- Never write to `.env` files directly.
- Never copy production secrets (`.env.production`, cloud credentials, deploy keys) to a worktree.
- Always record copied state in `WORKTREE_NOTES.md` so `/worktree-end` can inventory it later.
