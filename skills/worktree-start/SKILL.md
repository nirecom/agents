---
name: worktree-start
description: Set up a git worktree for a parallel-session task and copy required gitignored state
user-invocable: false
---

Set up a new linked worktree and initialize its gitignored state before starting work.

**Personal config:** Set `WORKTREE_BASE_DIR` in your agents config to customize the worktree
base path. Default: `~/git/worktrees`. Windows example: `WORKTREE_BASE_DIR=C:\git\worktrees`.

## Procedure

Read `rules/branch.md` and `rules/worktree.md` before WS-1 — both on-demand-only, never auto-injected; WS-1 needs the worktree criteria and WS-2 derives the branch name and type from the naming convention.
Read `rules/ops.md` before WS-5 — on-demand-only, never auto-injected; it owns the recovery-options-first decision path any directory or worktree removal a path collision tempts must pass through.

WS-1. Verify the task fits the worktree criteria in `rules/worktree.md` (fit table).
   If it does not fit, report why and stop — set `ENFORCE_WORKTREE=off` in agents config
   and work on main directly instead.

WS-2. Derive the task name and branch type — always automatic, never asked of the user:
   Run `bash "$AGENTS_CONFIG_DIR/skills/worktree-start/scripts/derive-worktree-name.sh"`, adding `--headless <label>` when the caller cannot present `AskUserQuestion` (running as a subagent or forked execution context) or when no workflow session hosts this run.
   Read `TASK_NAME=`, `BRANCH_TYPE=`, and `REPO_NAME=` from its stdout — `REPO_NAME` is the validated `<REPO_NAME>` path component; never infer it yourself. Non-zero exit → surface its stderr and stop; never substitute a name of your own and never ask the user for one.
   **Reuse-safety check**: run `git worktree list --porcelain` and find the entry whose `worktree` line equals `<WORKTREE_BASE_DIR>/<TASK_NAME>/<REPO_NAME>` — normalize both sides before comparing: convert every backslash to a forward slash and every MSYS-style `/c/<rest>` path to its `C:/<rest>` form (or vice versa), then strip any trailing slash, then lowercase both sides when the filesystem is case-insensitive (Windows, and default macOS). No entry → continue to WS-3. An entry exists → an existing path is not proof it is safe to attach to, so reuse only when all three hold:
   - Its `branch` line equals `refs/heads/<BRANCH_TYPE>/<TASK_NAME>`; a different branch is a naming collision, not a reusable worktree — surface both paths and branches to the user and stop.
   - It carries neither a `locked` nor a `prunable` line; either means another process or a stale registration owns it — surface the reason and stop.
   - `git -C "<path>" status --porcelain` (standalone command, no chaining) prints nothing; non-empty output is another session's in-flight work — never delete or reset it; report the dirty path and stop.
     The derived task name is deterministic, so resolving the collision requires manual intervention outside this skill (wait for the other session, or remove/relocate that worktree by hand).
   A non-zero exit from `git worktree list --porcelain` or `git -C "<path>" status --porcelain` means ownership cannot be verified — treat it the same as the three failing conditions above: surface the command's stderr and stop.

   All three pass → print the path and branch to stdout, skip WS-3–WS-6 (already exists — do not run `git worktree add`), and continue at WS-7.

WS-3. Worktree path: `<WORKTREE_BASE_DIR>/<TASK_NAME>/<REPO_NAME>`. Branch name: `<BRANCH_TYPE>/<TASK_NAME>`. Report both in chat — do not ask for approval.

WS-4. Check for conflicts:
   ```
   git worktree list --porcelain
   ```
   Report any existing worktrees at the same path or on the same branch.

WS-5. Create the parent directory (platform-aware):
   - POSIX: `mkdir -p "<WORKTREE_BASE_DIR>/<TASK_NAME>"`
   - PowerShell: `New-Item -ItemType Directory -Force -Path "<WORKTREE_BASE_DIR>\<TASK_NAME>"`

   **Do NOT chain or pipe this command** (no `;`, `&&`, `||`, `|`, `$()`, backticks).
   `enforce-worktree.js` only grants its `New-Item -ItemType Directory` exemption to
   isolated commands — any shell operator removes the exemption and the command is
   rejected as a write from the main worktree. Run it as its own Bash call.
   The same rule applies to step WS-6 (`git worktree add`).

WS-6. Create the worktree (isolated command — same chaining caveat as step WS-5):
   ```
   git worktree add <path> -b <BRANCH_TYPE>/<TASK_NAME>
   ```

WS-7. Dispatch the `worktree-copy` worker per `skills/_shared/worker-dispatch.md`. Payload: `worktree_path` (Step WS-3 path), `branch` (`<BRANCH_TYPE>/<TASK_NAME>`), `session_id` (omit when unknown), `artifact_dir` (the `PLANS_DIR` from WD-1).

   Check `CONFIRM_WORKTREE` via Bash: `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_WORKTREE on'`
   `--headless` at WS-2 signals either no workflow session or a subagent/fork context where `AskUserQuestion` is unreachable — treat `CONFIRM_WORKTREE` as OFF in both cases.

   Response handling when `CONFIRM_WORKTREE=OFF`:
   - `status: complete` → surface summary, proceed.
   - `status: partial` → surface warning, proceed (non-blocking).
   - `status: failed` → surface error and stop.

   Response handling when `CONFIRM_WORKTREE=ON` (default):
   - `status: complete` → call `AskUserQuestion` to confirm copy results before proceeding.
   - `status: partial` → call `AskUserQuestion` in main (surface denied/errors via artifact log path); user must confirm or abort.
   - `status: failed` → surface error and stop.

WS-8. Enter the worktree: call the native `EnterWorktree` tool with the WS-3 path.
   One confirmation dialog for worktrees outside `.claude/worktrees/` is normal since v2.1.206.
   Protocol: `skills/_shared/worktree-transition.md`

WS-9. Final report: worktree path, branch, which gitignored state was copied, and whether the session entered the worktree (WS-8).

## Rules

- Never write to `.env` files directly.
- Never copy production secrets (`.env.production`, cloud credentials, deploy keys) to a worktree.
- Always record copied state in `WORKTREE_NOTES.md` so `/worktree-end` can inventory it later.
- Task-name validation lives in `scripts/derive-worktree-name.sh` (D5); it is the sole TASK_NAME validator (CPR-SSOT) and rejects any derived name failing `[a-zA-Z0-9][a-zA-Z0-9_-]*`, exiting non-zero. Never bypass it or hand-write a name.
- `<REPO_NAME>` in the worktree path is validated by the same script (D0) and emitted as `REPO_NAME=`; use that value verbatim.
- Never call `AskUserQuestion` to choose a task name or branch type — WS-2 is fully automatic in every context.
- WORKTREE_NOTES.md generation is owned by `bin/worktree-write-notes.js`. Do not write the
  file or edit `.git/info/exclude` manually.
- Report observations via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).
