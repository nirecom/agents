# Git Commands

## Commands for Other Directories

When running git commands outside the current working directory, always use
`git -C <path>` instead of `cd <path> && git ...`.

CORRECT: `git -C /path/to/repo log --oneline -5`
WRONG:   `cd /path/to/repo && git log --oneline -5`

`enforce-worktree.js` / `workflow-gate.js` honor `-C`'s target as the worktree (not CWD).

## Write Commands

Run git write commands (any subcommand that modifies state) as **separate sequential Bash calls** — do NOT chain them with `&&`.

## Force Push

- Prefer `--force-with-lease` over `--force` — it aborts when the remote ref has moved since your last fetch, preventing accidental clobber.
- Feature branches: `git push --force-with-lease` is auto-permitted by `settings.json`. State the reason in the Bash description (e.g., "rebase rewrote SHA X → Y").
- `main` / `master`: force-push is emergency-only. Procedure: user sets `ENFORCE_WORKTREE=off` → Claude executes the push → user restores `ENFORCE_WORKTREE=on`.
- `--force` and `-f` are auto-denied by `settings.json`.

> Guard note: `hooks/enforce-worktree.js` blocks all writes (including push) from the main worktree
> when `ENFORCE_WORKTREE=on`. The `settings.json` allow rules apply only from linked worktrees.
