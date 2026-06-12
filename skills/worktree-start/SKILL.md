---
name: worktree-start
description: Set up a git worktree for a parallel-session task and copy required gitignored state
user-invocable: false
---

Set up a new linked worktree and initialize its gitignored state before starting work.

**Personal config:** Set `WORKTREE_BASE_DIR` in your agents config to customize the worktree
base path. Default: `~/git/worktrees`. Windows example: `WORKTREE_BASE_DIR=C:\git\worktrees`.

## Procedure

1. Verify the task fits the worktree criteria in `rules/worktree.md` (fit table).
   If it does not fit, report why and stop — set `ENFORCE_WORKTREE=off` in agents config
   and work on main directly instead.

2. **Non-interactive mode** (skip the interactive flow when both flags are provided):
   If `--task-name <name>` and `--branch-type <type>` are both supplied as arguments:
   - Validate `<name>` matches `[a-zA-Z0-9_-]+`; if invalid, abort with error.
   - Validate `<type>` is one of `feature` / `fix` / `refactor` / `docs` / `chore`; if invalid, abort with error.
   - Adopt the provided values and skip `AskUserQuestion`.
   - **Idempotency check**: run `git worktree list --porcelain`. If a worktree already exists at `<WORKTREE_BASE_DIR>/<task-name>/<repo-name>`, print that path to stdout and exit 0 (reuse — do not run `git worktree add`).

   Otherwise (interactive): estimate the task name from the user's message. Task names must match `[a-zA-Z0-9_-]+`
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

   **Do NOT chain or pipe this command** (no `;`, `&&`, `||`, `|`, `$()`, backticks).
   `enforce-worktree.js` only grants its `New-Item -ItemType Directory` exemption to
   isolated commands — any shell operator removes the exemption and the command is
   rejected as a write from the main worktree. Run it as its own Bash call.
   The same rule applies to step 6 (`git worktree add`).

6. Create the worktree (isolated command — same chaining caveat as step 5):
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

9. Run the automated copy using `.worktreeinclude`:

   a. Get the main worktree absolute path (already available from the prior steps, or run
      `git rev-parse --show-toplevel`). Use forward slashes — Git for Windows already
      returns forward slashes.

   b. Pipe a JSON payload to the copy script. Build the payload with Node to avoid
      shell quoting and backslash issues:
      ```
      node -e "process.stdout.write(JSON.stringify({mainRoot:process.argv[1],worktreePath:process.argv[2],includeFile:null}))" -- "<mainRoot>" "<step-3-path>" | node bin/worktree-copy-include.js
      ```
      Files listed in `.worktreeinclude` that are also gitignored will be copied.
      Files listed in `.worktree-copyignore` are always denied, regardless of `.worktreeinclude`.

   c. Display the `"copied"` list to the user.
   d. If `"denied"` is non-empty, report: "Skipped by .worktree-copyignore: <files>".
   e. If `"errors"` is non-empty, report them to the user.
      **Symlink note:** "Symlink source rejected: .env" is expected when `.env` is a
      symlink (common in dotfiles setups). It does NOT require manual action if
      `AGENTS_CONFIG_DIR` is already set in the parent shell environment — verify
      with `echo "$AGENTS_CONFIG_DIR"` after `EnterWorktree`. Only escalate if
      the variable is unset.
   f. If stderr contains `WARN:`, display it and ask the user to verify that the
      pattern is also present in `.gitignore`.

   Then check CONFIRM_WORKTREE via Bash:
     `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_WORKTREE on && echo OFF || echo ON'`
   - stdout `OFF`: auto-continue without `AskUserQuestion`.
   - stdout `ON`: call `AskUserQuestion` to let the user confirm the copy results before proceeding.
   - In non-interactive mode (`--task-name` + `--branch-type` provided), treat `CONFIRM_WORKTREE` as OFF regardless of config — `AskUserQuestion` cannot be called in subagent contexts.

10. Generate `WORKTREE_NOTES.md` + register in `.git/info/exclude`. Pass Step 9 (b) stdout
    via `COPIED_JSON` env var (the script reads `.copied` from it).

    POSIX:
    ```
    COPIED_JSON='<step-9-stdout>' node bin/worktree-write-notes.js "<mainRoot>" "<step-3-path>" "<type>/<task-name>" "" "<session-id>"
    ```
    Claude Code が現セッションの session-id を持つ場合はそれを使用。不明な場合は空文字でも可（既存挙動）。

    PowerShell:
    ```
    $env:COPIED_JSON = '<step-9-stdout>'
    node bin/worktree-write-notes.js "<mainRoot>" "<step-3-path>" "<type>/<task-name>" "" "<session-id>"
    ```
    Claude Code が現セッションの session-id を持つ場合はそれを使用。不明な場合は空文字でも可（既存挙動）。

    `<mainRoot>`: main repository root from Step 9 (a) — never a linked worktree path.
    Exit 0 with `notesWritten:true` = success. Exit 1 = investigate stderr and re-run.

11. Final report: worktree path, branch, and which gitignored state was copied.

## Rules

- Never write to `.env` files directly.
- Never copy production secrets (`.env.production`, cloud credentials, deploy keys) to a worktree.
- Always record copied state in `WORKTREE_NOTES.md` so `/worktree-end` can inventory it later.
- Task name validation: reject names that fail `[a-zA-Z0-9_-]+` — do not proceed with invalid names.
- WORKTREE_NOTES.md generation is owned by `bin/worktree-write-notes.js`. Do not write the
  file or edit `.git/info/exclude` manually.
- Known limit: filenames containing `'` break the POSIX `COPIED_JSON='...'` quoting. Fall
  back to `COPIED_JSON="$(cat file.json)"` if needed.
- Report observations per rules/supervisor-reporting.md.
