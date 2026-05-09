# settings.json Design

**Allow rules** — read-only operations only:
- Git read commands (`git status`, `git log`, `git diff`, `git branch`, etc.)
- `git -C <path>` for cross-directory git reads — preferred method
- Filesystem reads (`ls`, `tree`, `head`, `tail`, `grep`, `wc`, etc.)
- `.env.example` reads (`.env` itself is denied)

**Deny rules** — four categories (wildcard prefix `*` to catch compound commands):

| Category | Target | Examples |
|:---|:---|:---|
| Environment files | `.env`, `.env.*` | Denied in Read, Grep, and Bash |
| Destructive commands | Force push, hard reset, deletion | `git push --force`, `rm -rf`, `dd` |
| Credentials | SSH keys, AWS, Docker, kube | `~/.ssh/**`, `~/.aws/**`, `~/.kube/**`, etc. |
| Direct dotfile editing | Home directory dotfiles | `~/.bashrc`, `~/.zshrc`, etc. denied in Edit |

**Hook format**: Nested format — `matcher` + `hooks` array. Timeout in seconds.

```json
{ "matcher": "Edit|Write", "hooks": [{ "type": "command", "command": "node .../hook.js", "timeout": 5 }] }
```

**Hooks**:
- `scan-outbound.js` (PreToolUse, matcher: `Bash`) — scans commands for private info patterns
- `block-dotenv.js` (PreToolUse, matcher: `Bash|Read|Grep|Glob|Edit|Write|MultiEdit`) — blocks `.env` file access (read and write).
  Sanitizes git commit messages (`git commit` and `git -C <path> commit`) to avoid false positives
- `workflow-gate.js` (PreToolUse, matcher: `Bash`) — enforces all 10 workflow steps before
  `git commit`. Reads state from `~/.claude/projects/workflow/<session-id>.json`. Fail-safe:
  blocks on missing session_id, missing state file, or corrupted JSON. Evidence-based override
  for `write_tests` (staged `tests/` files) and `docs` (staged `*.md` files).
  **Docs-only short-circuit**: when every staged file matches the human-facing docs allowlist
  (regex `^(docs\/.+\.md|(README|CHANGELOG|CONTRIBUTING|LICENSE)\.md)$/i`),
  only `user_verification` is required — research/plan/write_tests/run_tests/review_security
  are automatically bypassed. Behavior/prompt `.md` files (`CLAUDE.md`, `SKILL.md`, any
  subdirectory `README.md`) are NOT eligible — they are treated as code.
  Use case: follow-up commits that tick a checkbox in `docs/todo.md`, append to
  `docs/history.md`, or refresh the user-visible description in root `README.md`.
  Replaces `check-docs-updated.js` and `check-tests-updated.js`
- `workflow-mark.js` (PostToolUse) — intercepts `echo "<<WORKFLOW_MARK_STEP_step_status>>"` and
  `echo "<<WORKFLOW_RESET_FROM_step>>"` via strict regex on `tool_input.command`. Supports `&&`-chained
  sentinel commands (all-or-nothing: any non-sentinel part rejects the whole command). After each
  successful step completion, appends a `[workflow]` next-step hint to `additionalContext` via
  `nextStepHint()` (defined in `hooks/lib/workflow-state.js`) to guide Claude toward the next skill
- `workflow-run-tests.js` (PostToolUse, matcher: `Bash`) — auto-marks `run_tests` based on Bash exit
  code. Detects test runner commands by path pattern (`tests/`) and known runner names. exit 0 →
  `complete`; exit ≠ 0 → `pending` (last-run-wins). Sentinel echoes and read-only commands excluded
- `session-start.js` (SessionStart) — appends `CLAUDE_SESSION_ID=<sid>` to `CLAUDE_ENV_FILE`;
  inherits prior session's workflow steps if cwd+branch match found in transcript (see
  [workflow.md — Session ID flow](workflow.md)); otherwise creates fresh state; outputs
  `additionalContext` containing session_id, all 10 step statuses, and a `NEXT ACTION:` line
  pointing to the next pending skill; runs zombie cleanup
- `stop-cleanup-reminder.js` (Stop) — fires after every Claude response turn; if
  `user_verification` is complete and `cleanup` is still pending, outputs
  `{"decision":"block","reason":"..."}` (exit 2) to remind Claude about step 10 (worktree-end
  or branch deletion). Silent (exit 0) for main path or when cleanup is already done.
  Reads `session_id` from stdin (provided by Claude Code) as fallback when `CLAUDE_ENV_FILE`
  is unavailable. Guards against infinite loops via `stop_hook_active` check.
- `post-compact.js` (PostCompact) — re-injects session_id into conversation context after
  compaction so the transcript retains the marker for future inheritance lookups
- `check-cross-platform.js` (PreToolUse, matcher: `Bash`) — blocks `git commit` when
  platform-specific files (`install/win/` ↔ `install/linux/`) are staged without counterpart
  changes. Skip mechanisms: `.cross-platform-skiplist` (permanent, base tool names) and
  `.git/.cross-platform-reviewed` (one-time, HEAD hash)
- `enforce-worktree.js` (PreToolUse, matcher: `Bash|Edit|Write|MultiEdit`) — when
  `ENFORCE_WORKTREE=on` (default), blocks writes from the main worktree regardless
  of branch, and blocks default-branch edits. Main-worktree detection: `--git-common-dir
  == --git-dir` (linked worktrees have differing values). Default-branch detection:
  `refs/remotes/origin/HEAD` → local `main`/`master` → `init.defaultBranch` → fallback
  `main`. Override via `DEFAULT_BRANCHES=develop,trunk,...` (comma-separated).
  Allows: HEAD unborn, detached HEAD, files outside any git repo, `git worktree
  add/remove/prune` lifecycle commands, PowerShell `New-Item -ItemType Directory`.
  Defense-in-depth at commit time via the bash block in `pre-commit`. Falsy values
  (`off|0|false|no|disabled`, case-insensitive) opt out.
  `ENFORCE_WORKTREE_EXCLUDE`: semicolon-separated glob patterns. When ALL staged files
  match at least one pattern, the main-checkout and protected-branch gates in `pre-commit`
  are skipped (the private-info scanner still runs). Patterns are absolute paths with `**`
  (any path segments, including zero) and `*` (any non-separator chars). Matching is
  case-insensitive on Windows. Implementation: `hooks/lib/glob-match.js`.
  Example: `ENFORCE_WORKTREE_EXCLUDE=C:\git\**\todo.md;<redacted>\my-specs-repo\**\todo.md`
  **gh command classification** — Bash write-detection uses `hooks/lib/bash-write-patterns.js`:
  - **Group A (always-allow / classified "read")**: `gh pr create/edit/close/comment/review`,
    `gh issue create/edit/close/comment`, `gh repo create/edit/rename/archive` — coordination
    and metadata-only; the guard never fires on these.
  - **Group B (classified "write", session-scope check)**: `gh pr merge`, `gh issue delete`,
    `gh repo delete`, `gh release create/edit/delete/upload`, `gh api` with
    POST/PUT/PATCH/DELETE in any flag form (`-X`, `-XVERB`, `-X=VERB`, `--method`,
    `--method=`). Group B commands additionally verify that the detected repo root is
    in the session scope (CWD repo + `ENFORCE_WORKTREE_EXTRA_REPOS`).
  `ENFORCE_WORKTREE_EXTRA_REPOS`: semicolon-separated list of additional repo roots
  or parent directories treated as in-scope for Group B gh writes. If an entry
  is not itself a git repo, its immediate subdirectories are scanned (depth 1)
  and any git repos found are added. The CWD repo is always included.
- `post-push-workflow-reset.js` (UserPromptSubmit) — detects push milestone:
  if `last_pushed_sha` (recorded by `workflow-mark.js` on a successful `git push`)
  equals current HEAD, resets workflow step `branching_complete` to pending and
  clears `last_pushed_sha`. Forces fresh branch/worktree creation for the next task.

**Permission glob matching**: Permissions are matched against the entire command string.
`&&` does not split into subcommands. `Bash(git commit *)` does not match
`cd /path && git commit -m msg` (starts with `cd`). Deny rules use a leading `*`
(e.g., `*git commit --amend*`) to catch compound commands. Only interactive approval
("Yes, don't ask again") splits subcommands and saves individual rules (separate mechanism).

**Known limitations**:
- PreToolUse hook on Edit|Write bypasses the "Ask before edits" dialog (hook success =
  permission granted). Delegate Edit|Write scanning to the pre-commit hook.
- Hook format must be nested. Flat format (matcher/command/timeout at the same level) causes
  the entire settings.json to be skipped.
- VSCode's "Ask before edits" mode covers Edit/Write only — Bash commands do not trigger
  the ask dialog.
- Hot-reloading of settings.json hook changes is unreliable. Restart Claude Code after changes.

## AWS Permission Posture

Claude Code operates with read-only AWS access during scan skills. Recommended IAM grants:
- `ec2:Describe*`, `s3:ListAllMyBuckets`, `s3:ListBucket`, `s3:GetBucketAcl`, `s3:GetBucketPolicyStatus`
- `iam:List*`, `iam:Get*` (not Create/Put/Attach/Delete)
- `ce:GetCostAndUsage`, `ce:GetCostForecast`
- `ecs:List*`, `ecs:Describe*`, `lambda:List*`, `lambda:Get*`
- `elasticloadbalancing:Describe*`, `apigateway:GET`, `apigatewayv2:GET`, `cloudfront:List*`, `cloudfront:Get*`
- `cloudtrail:Describe*`, `cloudtrail:Get*`, `guardduty:List*`, `guardduty:Get*`, `config:Describe*`, `securityhub:Describe*`
- Explicit deny: `*:Delete*`, `*:Remove*`, `*:Terminate*`, `*:Put*`

`settings.json` deny/ask rules are defense-in-depth. Server-side IAM is the authoritative layer.
IAM policy setup is tracked in `docs/todo.md`.
