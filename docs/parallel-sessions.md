# Parallel Sessions: Worktree Workflow

How to run multiple Claude Code sessions on the same repository simultaneously
without stepping on each other.

## Why Worktrees

Without worktrees, parallel sessions on the same repository share one working tree.
Three failure modes occur:

1. **Race on default branch.** Session A commits to main; session B's rebase/push
   conflicts. One session's work is silently overwritten or rebased away.
2. **Gitignored state collision.** Both sessions share one `.env`, one `data/`, one
   `node_modules`. A long-running process in session A is killed by session B's `npm install`.
3. **Unclear ownership.** Partial edits from two sessions appear mixed in `git status`.
   Attribution and rollback become ambiguous.

Git linked worktrees give each session an independent working tree with a shared object
store. Sessions can work concurrently with full isolation.

## Path Layout

All worktrees follow a two-level layout:

```
<WORKTREE_BASE_DIR>/<task-name>/<repo-name>
```

| Variable | Default | Description |
|---|---|---|
| `WORKTREE_BASE_DIR` | `~/git/worktrees` | Root for all worktrees. Set in agents config (`.env`). |
| `task-name` | from user message | Short task identifier, shared across repos (`[a-zA-Z0-9_-]+`). |
| `repo-name` | git repo directory name | Set automatically by `/worktree-start`. |

**Windows example** (set in `.env`):
```
WORKTREE_BASE_DIR=C:\git\worktrees
```

With two repos sharing one task:
```
C:\git\worktrees\
  auth-refactor\
    agents\          ← worktree for agents repo
    dotfiles\        ← worktree for dotfiles repo
```

## Lifecycle

```
/worktree-start <task-name>
│  Confirms task-name + branch type → path
│  mkdir -p <base>/<task>
│  git worktree add <path> -b <type>/<task>
│  Copies gitignored state (.env etc.)
│  Writes WORKTREE_NOTES.md
│
│  ← work happens here (multiple sessions OK) →
│
/commit-push              (from inside the worktree)
│  git add / commit / push
│  gh pr create --fill (if no open PR)
│  AskUserQuestion: merge / wait / abort
│
/worktree-end             (after work is done)
   gh pr view → reuse or create PR
   AskUserQuestion: merge / wait / abort
   merge → gh pr merge --squash --delete-branch
   cleanup:
     git worktree remove <path>
     git worktree prune
     rmdir <base>/<task> (if empty)
     git branch -d <branch>
     git fetch --prune
```

## Defense Layers

Three enforcement layers prevent accidental writes to the main checkout:

| Layer | Mechanism | Trigger |
|---|---|---|
| PreToolUse hook | `enforce-worktree.js` (Node.js) | Every Edit / Write / MultiEdit / Bash write tool call |
| Pre-commit hook | `pre-commit` (bash) | Every `git commit` |
| Skill guidance | `/worktree-start` procedure | Session setup |

The hook blocks when:
- The tool targets the **main checkout** (`--git-common-dir == --git-dir`), regardless of branch.
- The tool targets a **protected branch** (main/master) even inside a linked worktree.

## Off-mode (`ENFORCE_WORKTREE=off`)

For genuinely trivial changes (single-commit typo, lock-file-only update):

```
# In agents config (.env)
ENFORCE_WORKTREE=off
```

Effect:
- `enforce-worktree.js` and `pre-commit` skip all blocking.
- `/commit-push` skips the PR step.
- `/worktree-end` shows the PR URL but does not prompt for merge.

Re-enable `ENFORCE_WORKTREE=on` immediately after the trivial commit.

## AUTO_MERGE_PR

Controls whether `/commit-push` and `/worktree-end` prompt for merge after creating the PR.

| Value | Behavior |
|---|---|
| `on` (default) | Creates PR → `AskUserQuestion`: merge / wait / abort |
| `off` | Creates PR → displays URL → stops (merge left to user) |

Set in agents config (`.env`):
```
AUTO_MERGE_PR=off   # CI must pass first, merge manually
```

## Troubleshooting

**Bash write blocked on main checkout:**
```
ENFORCE_WORKTREE: write blocked. Reason: main checkout (branch 'main').
```
→ Run `/worktree-start <task-name>` and continue from the worktree.

**Stale worktree entry after manual deletion:**
```
git worktree prune
git worktree list     # verify
```

**Hook blocks a read-only command incorrectly:**
The Bash classifier uses pattern matching and has false positives (e.g. `echo "x > y"`).
Use `ENFORCE_WORKTREE=off` temporarily, or restructure the command to avoid the matched pattern.

**`gh pr create` fails — PR already exists:**
`/worktree-end` is idempotent: it calls `gh pr view` first and reuses an open PR.
If the PR was closed manually, re-open it on GitHub before running `/worktree-end`.

**`git worktree remove` fails with dirty working tree:**
Do not use `--force`. Review uncommitted changes first:
```
git -C <path> status
git -C <path> stash   # if changes should be preserved
git worktree remove <path>
```
