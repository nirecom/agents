---
name: worktree-start
description: Set up a git worktree for a parallel-session task and copy required gitignored state
user-invocable: false
---

Set up a new linked worktree and initialize its gitignored state before starting work.

**Personal config:** Set `WORKTREE_BASE_DIR` in your agents config to customize the worktree
base path. Default: `~/git/worktrees`. Windows example: `WORKTREE_BASE_DIR=C:\git\worktrees`.

## Procedure

WS-1. Verify the task fits the worktree criteria in `rules/worktree.md` (fit table).
   If it does not fit, report why and stop — set `ENFORCE_WORKTREE=off` in agents config
   and work on main directly instead.

WS-2. **Non-interactive mode** (skip the interactive flow when both flags are provided):
   If `--task-name <name>` and `--branch-type <type>` are both supplied as arguments:
   - Validate `<name>` matches `[a-zA-Z0-9_-]+`; if invalid, abort with error.
   - Validate `<type>` is one of `feature` / `fix` / `refactor` / `docs` / `chore`; if invalid, abort with error.
   - Adopt the provided values and skip `AskUserQuestion`.
   - **Idempotency check**: run `git worktree list --porcelain`. If a worktree already exists at `<WORKTREE_BASE_DIR>/<task-name>/<repo-name>`, print that path to stdout and exit 0 (reuse — do not run `git worktree add`).

   Otherwise (interactive): estimate the task name from the user's message. Task names must match `[a-zA-Z0-9_-]+`
   (no slashes, dots, spaces, or shell metacharacters).
   Estimate the branch type: `feature` / `fix` / `refactor` / `docs` / `chore`.
   Ask the user to confirm both (or suggest corrections) with `AskUserQuestion`.

WS-3. Compute the canonical worktree path and show it to the user for final confirmation:
   ```
   <WORKTREE_BASE_DIR>/<task-name>/<repo-name>
   ```
   Branch name: `<type>/<task-name>`

WS-4. Check for conflicts:
   ```
   git worktree list --porcelain
   ```
   Report any existing worktrees at the same path or on the same branch.

WS-5. Create the parent directory (platform-aware):
   - POSIX: `mkdir -p "<WORKTREE_BASE_DIR>/<task-name>"`
   - PowerShell: `New-Item -ItemType Directory -Force -Path "<WORKTREE_BASE_DIR>\<task-name>"`

   **Do NOT chain or pipe this command** (no `;`, `&&`, `||`, `|`, `$()`, backticks).
   `enforce-worktree.js` only grants its `New-Item -ItemType Directory` exemption to
   isolated commands — any shell operator removes the exemption and the command is
   rejected as a write from the main worktree. Run it as its own Bash call.
   The same rule applies to step WS-6 (`git worktree add`).

WS-6. Create the worktree (isolated command — same chaining caveat as step WS-5):
   ```
   git worktree add <path> -b <type>/<task-name>
   ```

WS-7. Invoke `worktree-copy-worker` via Task tool. Build input JSON with Node to avoid quoting issues, passing: `main_root` (resolve via `git rev-parse --show-toplevel`), `worktree_path` (Step WS-3 path), `branch` (`<type>/<task-name>`), `session_id` (current session, empty string if unknown), `agents_config_dir` (resolve absolute path from `$AGENTS_CONFIG_DIR`), `artifact_dir` (`PLANS_DIR` resolved by calling `bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"` directly at this callsite).

   Check `CONFIRM_WORKTREE` via Bash: `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_WORKTREE on'`
   In non-interactive mode (`--task-name` + `--branch-type` provided), treat `CONFIRM_WORKTREE` as OFF — `AskUserQuestion` cannot be called in subagent contexts.

   Response handling when `CONFIRM_WORKTREE=OFF`:
   - `status: complete` → surface summary, proceed.
   - `status: partial` → surface warning, proceed (non-blocking).
   - `status: failed` → surface error and stop.

   Response handling when `CONFIRM_WORKTREE=ON` (default):
   - `status: complete` → call `AskUserQuestion` to confirm copy results before proceeding.
   - `status: partial` → call `AskUserQuestion` in main (surface denied/errors via artifact log path); user must confirm or abort.
   - `status: failed` → surface error and stop.

WS-8. Final report: worktree path, branch, and which gitignored state was copied.

## Rules

- Never write to `.env` files directly.
- Never copy production secrets (`.env.production`, cloud credentials, deploy keys) to a worktree.
- Always record copied state in `WORKTREE_NOTES.md` so `/worktree-end` can inventory it later.
- Task name validation: reject names that fail `[a-zA-Z0-9_-]+` — do not proceed with invalid names.
- WORKTREE_NOTES.md generation is owned by `bin/worktree-write-notes.js`. Do not write the
  file or edit `.git/info/exclude` manually.
- Report observations per rules/supervisor-reporting.md.
