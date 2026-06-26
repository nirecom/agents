# settings.json Design

**Allow rules** — read-only operations only:
- Git read commands (`git status`, `git log`, `git diff`, `git branch`, etc.)
- `git -C <path>` for cross-directory git reads — preferred method
- Filesystem reads (`ls`, `tree`, `head`, `tail`, `grep`, `wc`, etc.)
- `.env.example` reads (`.env` itself is denied)

**Deny rules** — four categories (wildcard prefix `*` to catch compound commands):

| Category | Target |
|:---|:---|
| Environment files | `.env`, `.env.*` |
| Destructive commands | Force push, hard reset, deletion |
| Credentials | SSH, GPG, AWS, Azure, gh, git, Docker, kube, npm, PyPI, gem, netrc, pgpass, MySQL, curl, Maven, Gradle, Terraform |
| Direct dotfile editing | Home directory dotfiles |

See `docs/security-policy.md` for the full pattern list.

**Hook format**: Nested format — `matcher` + `hooks` array. Timeout in seconds.

```json
{ "matcher": "Edit|Write", "hooks": [{ "type": "command", "command": "node .../hook.js", "timeout": 5 }] }
```

**Hooks**:
- `scan-outbound.js` (PreToolUse, matcher: `Bash`) — scans commands for private info patterns
- `block-dotenv.js` (PreToolUse, matcher: `Bash|Read|Grep|Glob|Edit|Write|MultiEdit`) — blocks `.env` file access (read and write).
  Sanitizes git commit messages (`git commit` and `git -C <path> commit`) to avoid false positives
- `block-credentials.js` (PreToolUse, matcher: `Bash|Read|Grep|Glob|Edit|Write|MultiEdit|editFiles|runInTerminal|runCommands`) — blocks Read/Edit/Write/Grep/Glob/Bash access to 22 credential-path families (24 protected roots; Terraform spans 3 roots): SSH keys, GnuPG, AWS, Azure, gh CLI config, git credentials, Docker config, kube, npm, PyPI, gem, netrc, pgpass, MySQL, curl, Maven, Gradle, Terraform, gcloud SDK, HashiCorp Vault, Cargo, 1Password CLI. Supersedes `block-ssh-private-key.js` (issue #254). WORKFLOW_OFF does NOT bypass. Path table: `CREDENTIALS_TABLE` in `hooks/block-credentials.js`. Recognizes `~`, `$HOME`, `${HOME}`, `$USERPROFILE`, `${USERPROFILE}`, and dot-segment forms; additionally recognizes the corresponding `/root/<tail>` sibling of every `~/`-rooted family (same path with `~/` stripped; see `CREDENTIALS_TABLE` in `hooks/block-credentials.js`). `..` traversal resolved by `path.posix.normalize`.
- `block-subagent-sentinels.js` (PreToolUse, matcher: `Bash|runInTerminal|runCommands`) — blocks
  `WORKFLOW_*` sentinel echoes issued from subagents. Sentinels are reserved for the orchestrator
  (main conversation); subagents cannot drive the workflow state machine. Detection uses the
  `isStrictSentinel`, `CHAIN_BOUNDARY_SENTINEL_DQ_RE`, and `CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE`
  patterns from `hooks/lib/sentinel-patterns.js`. Subagent identification via `agent_id` presence
  (see `hooks/lib/subagent-detect.js`). Fail-open: approves on malformed stdin or absent `agent_id`.
  Defense-in-depth with the `workflow-mark.js` PostToolUse backstop (C2).
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
  sentinel commands (all-or-nothing: any non-sentinel part rejects the whole command). Step sequencing
  is oracle-driven: the model queries `bin/workflow/next-step` after each completion rather than
  receiving a static prose hint
- `show-plan-link.js` — PostToolUse on Write. Always emits a `Plan file written: <path>` breadcrumb when a final plan artifact (intent/outline/detail.md matching `*-(intent|outline|detail).md` directly under `~/.workflow-plans/`) is written. When `CONFIRM_<STEP>=on` (default) AND a VS Code session is detected (`TERM_PROGRAM=vscode` or `CLAUDE_CODE_ENTRYPOINT=claude-vscode`) AND `SHOW_PLAN_LINK_NO_AUTO_OPEN` is unset, additionally spawns a single `code --folder-uri <uri> <filePath>` invocation (raises window and opens file atomically, eliminating the two-spawn timing race — #546 Gap 3). `normalizeCwd()` is applied at the entry of `workspaceFolderUriFrom` to convert Unix-style Git Bash paths (e.g. `/c/git/agents`) to `C:/git/agents` before URI construction, fixing multi-window routing on Windows. URI source ladder: `input.cwd` → `process.cwd()` → bare `code -r` (no folder-uri). Folder URI path segments are percent-encoded via `encodeURIComponent` for spaces / `#` / `%` / non-ASCII / UNC support (#492). Windows uses `cmd.exe /d /s /c code ...` per spawn (CVE-2024-27980 mitigation). VS Code 1.121 regression: when `--folder-uri` and a file path are passed together, the file-open arg is silently dropped; fixed in 1.122+. Users on 1.121 must click the breadcrumb manually — no fallback provided (#546). Fail-open: spawn errors do not abort the hook.
- `show-diff.js` (PreToolUse, matcher: `Write`) — shows an inline diff in chat for any final
  plan artifact written under `~/.workflow-plans/` (non-draft direct children:
  `*-(intent|outline|detail).md`). When the corresponding `CONFIRM_<STEP>` flag is off, the
  diff is suppressed (#445). Draft artifacts (`drafts/` subdirectory) are always suppressed.
- `workflow-run-tests.js` (PostToolUse, matcher: `Bash`) — auto-marks `run_tests` based on Bash exit
  code. Detects test runner commands by path pattern (`tests/`) and known runner names. exit 0 →
  `complete`; exit ≠ 0 → `pending` (last-run-wins). Sentinel echoes and read-only commands excluded
- `session-start.js` (SessionStart) — appends `CLAUDE_SESSION_ID=<sid>` to `CLAUDE_ENV_FILE`;
  inherits prior session's workflow steps if cwd+branch match found in transcript (see
  [workflow.md — Session ID flow](workflow.md)); otherwise creates fresh state; outputs
  `additionalContext` containing session_id, all 14 step statuses, and a `NEXT ACTION:` line
  from the oracle (`bin/workflow/next-step`); runs zombie cleanup
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
  Example: `ENFORCE_WORKTREE_EXCLUDE=C:\git\**\todo.md;C:\LLM\ai-specs\**\todo.md`
  Built-in (non-overridable): `.worktree-backup/**` is always excluded so `/worktree-end` Step 5 can copy gitignored files to `.worktree-backup/` even when Bash CWD has reset to the main worktree.
  **gh command classification** — Bash write-detection uses `hooks/lib/bash-write-patterns.js`:
  - **Classified "write" (session-scope check applies)**: `gh pr merge`, `gh issue create/delete`,
    `gh repo delete`, `gh release create/edit/delete/upload`, `gh api` with
    POST/PUT/PATCH/DELETE in any flag form (`-X`, `-XVERB`, `-X=VERB`, `--method`,
    `--method=`), GitHub Contents API PUT (`repos/.../contents/...`), Git Data API
    POST/PATCH (`repos/.../git/{blobs,trees,commits,refs}`). Write commands verify that
    the detected repo root is in-scope (CWD repo + `ENFORCE_WORKTREE_EXTRA_REPOS`).
    `gh issue create` is sanctioned only via the `/issue-create` skill — bare invocation
    from the main worktree is blocked (#672).
  - **Classified "read" (guard never fires)**: `gh pr create/edit/close/comment/review`,
    `gh issue edit/close/comment`, `gh repo create/edit/rename/archive` — metadata-only,
    never changes tracked repo content.
  `ENFORCE_WORKTREE_EXTRA_REPOS`: semicolon-separated list of additional repo roots
  or parent directories treated as in-scope for gh write scope checks. If an entry
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
