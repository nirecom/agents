# Parallel Sessions: Worktree Workflow

How to run multiple Claude Code sessions on the same repository simultaneously
without stepping on each other.

## Why Worktrees

Without worktrees, parallel sessions on the same repository share one working tree.
Three failure modes occur:

1. **Race on default branch.** Session A commits to main; session B's rebase/push
   conflicts. One session's work is silently overwritten or rebased away.
2. **Unclear ownership.** Partial edits from two sessions appear mixed in `git status`.
   Attribution and rollback become ambiguous.
3. **Gitignored state collision.** Both sessions share one `.env`, one `data/`, one
   `node_modules`. A long-running process in session A is killed by session B's `npm install`.

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
│  Copies gitignored state via .worktreeinclude (automated)
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

## Gitignored State: `.worktreeinclude`

`/worktree-start` automatically copies gitignored files from the main worktree to the
new linked worktree. Two files in the repo root control what is copied:

| File | Purpose |
|---|---|
| `.worktreeinclude` | Allowlist — gitignore-syntax patterns for files to copy |
| `.worktree-copyignore` | Denylist — overrides `.worktreeinclude`; entries here are never copied |

**Copy conditions:** a file must match `.worktreeinclude` **and** be gitignored (`git ls-files --others --ignored`). Tracked files are never copied.

**Default `.worktreeinclude`** (agents repo):
```
.env
.env.local
.env.development
.env.test
.private-info-allowlist
```

**Default `.worktree-copyignore`** (always denied):
```
.env.production
.env.staging
*.pem / *.p12
*deploy*key* / *credential*.json / *service-account*.json
.worktree-backup/
.worktree-backup
```

The copy is **blackbox** — Claude never reads file contents, only paths. The mechanism (`bin/worktree-copy-include.js`) returns a JSON report: `{ copied[], skipped[], denied[], errors[] }`.

Negation patterns (`!foo`) in `.worktree-copyignore` are stripped and warned — the denylist cannot be opt-out overridden.

## Defense Layers

Three enforcement layers prevent accidental writes to the main worktree:

| Layer | Mechanism | Trigger |
|---|---|---|
| PreToolUse hook | `enforce-worktree.js` (Node.js) | Every Edit / Write / MultiEdit / Bash write tool call |
| Pre-commit hook | `pre-commit` (bash) | Every `git commit` |
| Skill guidance | `/worktree-start` procedure | Session setup |

The hook blocks when:
- The tool targets the **main worktree** (`--git-common-dir == --git-dir`), regardless of branch.
- The tool targets a **protected branch** (main/master) even inside a linked worktree.

## `ENFORCE_WORKTREE=on` vs `off`

| Behavior | `on` (default) | `off` |
|---|---|---|
| Writes from main worktree | Blocked — `enforce-worktree.js` (PreToolUse) + `pre-commit` | Allowed |
| Protected-branch commits | Blocked — `pre-commit` | Allowed |
| Merge gate (`gh pr merge` / `git push origin main`) | Blocks until `user_verification` complete — **unconditional** in both modes | Same — unconditional |
| PR flow in `/commit-push` | PR created; `AskUserQuestion`: merge / wait / abort | PR step skipped — commit goes direct |
| Worktree setup required | Yes — `/worktree-start <task>` before work begins | No |
| Intended use | Parallel features, multi-session work | Single trivial commits (typo, lockfile-only) |

Set in agents config (`.env`):
```
ENFORCE_WORKTREE=off   # trivial one-liner; re-enable immediately after
```

> **Note:** The merge gate (`user_verification` block on `gh pr merge` and protected-branch push)
> fires in **both** modes. It is enforced by `workflow-gate.js` independently of the worktree guard.

## Troubleshooting

**Bash write blocked on main worktree:**
```
ENFORCE_WORKTREE: write blocked. Reason: main worktree (branch 'main').
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
