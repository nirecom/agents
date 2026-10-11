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
| `task-name` | derived automatically | Short task identifier, shared across repos (`[a-zA-Z0-9][a-zA-Z0-9_-]*`). Derived by `/worktree-start` from the session intent — never asked for. |
| `repo-name` | git repo directory name | Set automatically by `/worktree-start`. |

**Windows example** (set in `.env`):
```
WORKTREE_BASE_DIR=C:\src\worktrees
```

With two repos sharing one task:
```
C:\src\worktrees\
  auth-refactor\
    agents\          ← worktree for agents repo
    dotfiles\        ← worktree for dotfiles repo
```

## Lifecycle

```
/worktree-start
│  Derives task-name + branch type → path
│  mkdir -p <base>/<task>
│  git worktree add <path> -b <type>/<task>
│  Copies gitignored state via .worktreeinclude (automated)
│  Writes WORKTREE_NOTES.md
│
│  ← work happens here (multiple sessions OK) →
│
/commit-push              (push_branch; from inside the worktree)
│  git add / commit / push
│  gh pr create --fill (if no open PR); never merges
│
/get-release-approval     (user_verification)
│  preflight (PR mergeable, verification gate)
│  USER_VERIFIED dialog — the one user confirmation
│
/deliver                  (deliver)
│  gh pr merge <PR number> --squash --delete-branch
│
/worktree-end             (cleanup; never merges)
   gh pr view → PR number, bootstrap check
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
| Delivery path | `pull_request`: `/commit-push` opens the PR (`push_branch`), `/deliver` merges it | `direct`: `push_branch` and `cleanup` are skipped; `/deliver` commits and pushes to main |
| Worktree setup required | Yes — `/worktree-start` before work begins | No |
| Intended use | Parallel features, multi-session work | Single trivial commits (typo, lockfile-only) |

Set in agents config (`.env`):
```
ENFORCE_WORKTREE=off   # trivial one-liner; re-enable immediately after
```

**Path exclusion (path-coverage)** — `ENFORCE_WORKTREE_EXCLUDE` exempts the given paths from
enforcement. An entry with a glob metachar (`*` / `**`) matches file paths via glob; a plain
path entry matches via path-boundary prefix (covering that path and its whole subtree). Both
`enforce-worktree.js` and `pre-commit` honor it. Glob and plain entries may be mixed:
```
ENFORCE_WORKTREE_EXCLUDE=C:\src\repo-a;C:\src\**\todo.md   # POSIX: /home/<user>/repo-a;/home/<user>/agents/docs/**/*.md
```

> **Migration:** `ENFORCE_WORKTREE_EXCLUDE_REPOS` is deprecated. Move the same entries to
> `ENFORCE_WORKTREE_EXCLUDE` (a one-time deprecation warning is printed until you do).

**Additional session-scope repos** — `ENFORCE_WORKTREE_ADDITIONAL_REPOS` (formerly
`ENFORCE_WORKTREE_EXTRA_REPOS`) lists extra repo roots recognized as targets for `gh` write
commands. The CWD repo is always included.

> **Note:** The merge gate (`user_verification` block on `gh pr merge` and protected-branch push)
> fires in **both** modes. It is enforced by `workflow-gate.js` independently of the worktree guard.

## New Repo Bootstrap (first commit on empty remote)

**When it fires:** the GitHub remote exists (was just created via `gh repo create` or the web UI) but has no default branch yet — `git ls-remote --symref origin HEAD` returns no `ref:` line.

**How it is detected:** `hooks/lib/bootstrap-state.js` exports `isRemoteInPreBootstrap(repoRoot)`. The probe runs `git ls-remote --symref origin HEAD` with `GIT_TERMINAL_PROMPT=0` / `GIT_ASKPASS=/bin/true` and a 5-second timeout, then classifies the result:
- `empty-repo` — exit 0 with empty stdout → bootstrap mode activates.
- `ok` — symref present → normal flow.
- `network` / `auth` / `not-found` / `timeout` / `spawn-error` / `unknown` → bootstrap mode does NOT activate; the error surfaces in the normal push/PR step.

**What happens automatically:**
- `/commit-push` runs the probe before pushing. On `empty-repo` it returns `status: bootstrap_pending` and completes `push_branch` with no push and no PR; the next steps carry the session on.
- `/get-release-approval` runs next and is the only place the `<<WORKFLOW_USER_VERIFIED: ...>>` sentinel is issued — the one user confirmation, exactly as on a normal delivery.
- `/deliver` finds no PR (`bin/workflow/pr-state` prints `PR_STATE=NONE`), re-runs the probe (the remote may have been bootstrapped externally in between), and on `empty-repo` routes to Step DL-3b, which calls `skills/deliver/scripts/bootstrap-complete.sh <worktree> <branch> <owner/repo> <session-id>`. The fourth argument lets the script check that `user_verification` is complete (exit 4 otherwise). The script:
  1. Re-probes once more (refuses to push if the remote is no longer empty).
  2. `git push -u origin <branch>:main`.
  3. `gh repo edit --default-branch main` (warn-only).
  4. Prints JSON with the bootstrap commit SHA, `default_branch_set` flag, and pushed ref.
- `/worktree-end` Step WE-4 sees `PR_STATE=NONE`, sets `BOOTSTRAP_MODE=1` with the commit SHA from `git rev-parse HEAD`, and carries on with inventory and cleanup. It never pushes or creates a PR.
- `capture-env.sh` (Step WE-8) takes the `BOOTSTRAP_MODE=1` shortcut: it skips the `gh pr view` / `mergeCommit` retry and synthesizes `PR_STATE="BOOTSTRAP"`, `MERGE_SHA=<bootstrap commit SHA>`, empty `PR_NUMBER`/`PR_URL`.
- The history/changelog append (`compose-doc-append-entry`) reads `BOOTSTRAP_MODE` from the env JSON and dispatches `--bootstrap --merge-commit <sha>` instead of `--pr <N>`. The resulting `docs/history.md` and `CHANGELOG.md` entries use `bootstrap initial commit, <sha-short>` instead of `(PR #N)`.

**What the user sees:**
- In `/commit-push`: "Remote has no default branch yet (new repo) — `/deliver` pushes the first commit as `main`."
- At `/get-release-approval`: the single USER_VERIFIED dialog. `/deliver` and `/worktree-end` then run without further prompts. The Final Report shows `BOOTSTRAP` as the PR state and lists the bootstrap commit SHA in place of a PR number.

**Troubleshooting:**
- **Probe misfires due to network/auth issues:** the probe classifies these as `network` / `auth` / `not-found` and lets the normal push path surface the error. The bootstrap routing only activates on `empty-repo`. If you genuinely have an empty remote but the probe keeps returning `auth`, fix credentials first.
- **`gh repo edit --default-branch main` fails:** treated as warn-only — the push still completes. Manual recovery: `gh repo edit --default-branch main` (or set it via the GitHub web UI under Settings → General → Default branch).
- **Bootstrap push fails (exit 1 or 3 from `bootstrap-complete.sh`):** `deliver` stays incomplete and no cleanup runs; investigate the push error (auth, branch protection, etc.), fix, and re-run `/deliver`. Exit 2 means the remote is no longer empty — re-run `/commit-push`. Exit 4 means approval is missing — run `/get-release-approval`.

## Migration Code Block Format

See `rules/coding.md` (Migration Code Blocks section) for the required format of temporary migration code blocks, including the `added YYYY-MM-DD` date field and `deletion-condition:` field that must accompany each block.

## Troubleshooting

**Bash write blocked on main worktree:**
```
ENFORCE_WORKTREE: write blocked. Reason: main worktree (branch 'main').
```
→ Run `/worktree-start` and continue from the worktree.

**Stale worktree entry after manual deletion:**
```
git worktree prune
git worktree list     # verify
```

**Hook blocks a read-only command incorrectly:**
The Bash classifier uses pattern matching and has false positives (e.g. `echo "x > y"`).
Use `ENFORCE_WORKTREE=off` temporarily, or restructure the command to avoid the matched pattern.

**Worktree sessions missing from the VS Code extension's session list:**
The `anthropic.claude-code` extension asks for sessions with `includeWorktrees` disabled, so a
session started from a linked worktree is never listed — and every extension auto-upgrade
restores that state. Run `bin/vscode-cc-repair/index.js` (see README.md), then
`Developer: Reload Window`.

**`gh pr create` fails — PR already exists:**
`/commit-push` is idempotent: it calls `gh pr view` first and reuses an open PR.
If the PR was closed manually, re-open it on GitHub before running `/deliver`.

**`git worktree remove` fails with dirty working tree:**
Do not use `--force`. Review uncommitted changes first:
```
git -C <path> status
git -C <path> stash   # if changes should be preserved
git worktree remove <path>
```
