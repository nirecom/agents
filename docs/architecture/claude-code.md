# Claude Code Configuration

## 1. Workflow State Machine

All 7 workflow steps are tracked in a per-session JSON state file and enforced at `git commit`
time by a PreToolUse hook.

### State file

Path: `~/.claude/projects/workflow/<session-id>.json` (never committed — outside any repo)

```json
{
  "version": 1,
  "session_id": "abc123",
  "cwd": "/path/to/project",
  "git_branch": "main",
  "created_at": "2026-04-12T10:00:00.000Z",
  "steps": {
    "research":          { "status": "complete", "updated_at": "..." },
    "plan":              { "status": "skipped",  "updated_at": "..." },
    "write_tests":       { "status": "complete", "updated_at": "..." },
    "run_tests":         { "status": "complete", "updated_at": "..." },
    "review_security":   { "status": "complete", "updated_at": "..." },
    "docs":              { "status": "complete", "updated_at": "..." },
    "user_verification": { "status": "complete", "updated_at": "..." }
  }
}
```

`cwd` and `git_branch` are optional (absent in states created before the inheritance feature).
`git_branch` is `null` for non-git directories and detached HEAD.

Statuses: `pending` | `in_progress` | `complete` | `skipped`
- `skipped`: allowed for `research`, `plan`, `write_tests`, and `review_security`
- `user_verification`: cannot be `skipped` — enforced at CLI and permission level

### Steps and owners

| Step | How completed |
|---|---|
| `research` | `/survey-code` or `/deep-research` skill (emits `WORKFLOW_MARK_STEP` marker) |
| `plan` | `/make-plan` skill (emits marker) |
| `write_tests` | `/write-tests` skill (emits marker) **or** staged `tests/` / `test/` files detected by `workflow-gate.js` |
| `run_tests` | PostToolUse hook (`workflow-run-tests.js`) auto-marks based on Bash exit code when command touches `tests/` or invokes a test runner. Manual fallback: `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"` |
| `review_security` | `/review-code-security` skill (emits `WORKFLOW_MARK_STEP` marker) **or** skipped via `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"` |
| `docs` | `/update-docs` skill (emits marker) **or** staged `docs/*.md` / `*.md` files detected by `workflow-gate.js` |
| `user_verification` | `echo "<<WORKFLOW_USER_VERIFIED>>"` — triggers `ask` permission dialog; user must approve |

`write_tests` and `docs` accept evidence-based completion: at commit time, `workflow-gate.js`
checks `git diff --cached --name-only` and treats staged test/doc files as proof of completion,
bypassing the state file entry for those steps. The state file still contains those rows
(created by `session-start.js` with status `pending`); the evidence override happens only in
the gate, not in the file.

`research` and `plan` can be bypassed with `skipped` status (written via
`echo "<<WORKFLOW_MARK_STEP_research_skipped>>"` etc.) when CLAUDE.md skip conditions are met.

Each skill's `## Completion` section runs `echo "<<WORKFLOW_MARK_STEP_<step>_complete>>"` as
the sole Bash command (no pipes, no `&&`, no redirection). The PostToolUse hook
(`workflow-mark.js`) intercepts this via strict anchored regex on `tool_input.command` and
calls `markStep()` directly using `session_id` from the hook's stdin JSON. This bypasses the
`CLAUDE_ENV_FILE` propagation issue in Bash tool subprocesses (Anthropic bug #27987).

Note: marker format uses `_` as separator (not `:`). Claude Code's permission glob parser
treats `:` as a named-parameter separator inside `Bash(...)` rules, causing silent match
failure (anthropics/claude-code#33601). Using `_` avoids this.

`user_verification` uses a dedicated marker `echo "<<WORKFLOW_USER_VERIFIED>>"` (DQ only,
single space, no SQ variant). This command is in the `ask` permission category — Claude must
request user approval via dialog before the echo runs.

### Session ID flow

```
Session start → session-start.js (SessionStart hook)
  appends CLAUDE_SESSION_ID=<sid> to CLAUDE_ENV_FILE
  if state file does not exist:
    resolves cwd (CLAUDE_PROJECT_DIR or process.cwd()) and git_branch
    scans ~/.claude/projects/<encoded-cwd>/<session_id>.jsonl (mtime desc, up to 10)
    for each transcript: collects ALL "Current workflow session_id: <prior-sid>"
      markers from SessionStart and PostCompact entries (in file order)
    tries each collected ID in reverse order (PostCompact/most-recent first):
      skip if: no state file, branch mismatch, or all-pending
      if user_verification=complete: stop trying this JSONL (task done, start fresh)
      else: copies matching session's steps (state inheritance)
    if no match found in any transcript: creates fresh state with all steps pending
  writes ~/.claude/projects/workflow/<sid>.json (includes cwd, git_branch)
  outputs additionalContext: "Current workflow session_id: <sid>\nState file: ..."
    (→ recorded in transcript for future sessions to find via the scan above)
  runs zombie cleanup (deletes state files older than 7 days)

Compaction → post-compact.js (PostCompact hook)
  reads session_id from hook stdin JSON
  outputs additionalContext: "Current workflow session_id: <sid>\nState file: ..."
  (re-injects session_id so transcript retains the marker after compaction)

Skill runs (/make-plan, /write-tests, etc.)
  → Completion section emits: echo "<<WORKFLOW_MARK_STEP_<step>_complete>>"
  → workflow-mark.js (PostToolUse hook) intercepts command
     reads session_id from hook stdin JSON (not CLAUDE_ENV_FILE)
     calls markStep(session_id, step, status)

git commit attempt → workflow-gate.js (PreToolUse hook)
  reads session_id from hook stdin JSON
  loads ~/.claude/projects/workflow/<session_id>.json
  docs-only short-circuit: if ALL staged files match the human-facing docs allowlist
    (docs/*.md or root README/CHANGELOG/CONTRIBUTING/LICENSE.md),
    only user_verification is checked; all other steps are bypassed
  for write_tests: also checks staged tests/ files (evidence override)
  for docs: also checks staged docs/*.md / *.md files (evidence override)
  approves if all steps complete/skipped; blocks with remediation message otherwise
```

State inheritance is cwd+branch scoped. The practical inheritance window is 7 days (zombie
cleanup limit). Parallel sessions: transcript mtime ordering ensures the most-recently-used
session wins. Non-git directories and detached HEAD both use `git_branch: null` — they match
each other but not named branches. Completed workflows (`user_verification: complete`) are
never inherited — the JSONL is skipped entirely so the new session starts fresh. PostCompact
entries take priority because they are appended after SessionStart and reflect the most
recent session_id in any given JSONL file.

### Fail-safe behavior

| Condition | Result |
|---|---|
| `session_id` missing from hook stdin | block |
| State file not found | block |
| State file corrupted (bad JSON) | block |
| Step `pending` or `in_progress` | block |
| Non-skippable step marked `skipped` | block |

To reset from a specific step (e.g., re-running code phase):
```
echo "<<WORKFLOW_RESET_FROM_<step>>>"
```
Marks all prior steps `complete`, resets target step and after to `pending`.

---

## 2. Session Sync

Syncs Claude Code session history (`~/.claude/projects/`) across multiple machines
(Windows, macOS, Linux).

**Problem**: Claude Code indexes projects by absolute path (e.g.,
`C:\Users\<user>\git\repo` → `~/.claude/projects/-C-Users-<user>-git-repo/`).
Paths containing the username differ across machines, making session reference and
resume impossible.

**Solution**: Use drive-root unified paths to eliminate username dependency,
and sync history via a private GitHub repo.

| Path | Purpose |
|---|---|
| (drive-root LLM dir) | LLM infrastructure (immovable — tightly coupled with NSSM services, TLS certs, GGUF model paths) |
| `C:\git\` | All other git repositories (Windows) |

**Sync method**: Initialize `~/.claude/projects/` as a git repo, syncing to
`nirecom/claude-sessions` (private). Init fetches existing remote history
(`fetch` + `reset`) before first commit so that 2nd+ machines inherit prior
session data without conflict.

| File | Repository | Responsibility |
|---|---|---|
| [install/win/session-sync-init.ps1](https://github.com/nirecom/dotfiles/blob/main/install/win/session-sync-init.ps1) | dotfiles | Initialization — Windows |
| [install/linux/session-sync-init.sh](https://github.com/nirecom/dotfiles/blob/main/install/linux/session-sync-init.sh) | dotfiles | Initialization — Linux/macOS |
| [bin/session-sync.ps1](https://github.com/nirecom/dotfiles/blob/main/bin/session-sync.ps1) | dotfiles | Daily operation — Windows |
| [bin/session-sync.sh](https://github.com/nirecom/dotfiles/blob/main/bin/session-sync.sh) | dotfiles | Daily operation — Linux/macOS |

**Sync scope**:

| Path | Synced | Reason |
|---|---|---|
| `~/.claude/projects/` | Yes | Session history (JSONL) |
| `~/.claude/settings.json` | No | Managed by dotfiles |
| `~/.claude/CLAUDE.md`, `rules/`, `skills/` | No | Managed by dotfiles |
| `~/.claude/statsig/`, `ide/`, `history.jsonl` | No | Machine-specific |

**Line ending control**: `.gitattributes` declares `* text eol=lf`. Preserves LF line endings
in JSONL files generated by Claude Code without conversion.

**Relationship with Web mode**: VS Code's Local/Web toggle provides Web mode (claude.ai/code),
but tasks requiring local filesystem, MCP servers, or NSSM service operations must use Local
mode. Local sessions are invisible to Web and vice versa. Self-hosted sync is necessary for
sharing Local mode session history.

**Automatic sync**:
- **Terminal startup**: `.profile_common` (Linux/macOS) and `profile.ps1` (Windows) run
  `git fetch + merge --ff-only` on `~/.claude/projects/` with 3-second timeout
- **`codes` function**: Opens VS Code in a new window (`--new-window`), polls for window
  closure via title matching (`wait-vscode-window.ps1` / `.sh`), then runs session-sync push.
  Each instance independently detects its own window. Push runs in quiet mode: shows a single
  Windows toast notification on completion or failure (WinRT API, no external modules).
  Linux: `notify-send` fallback.

**Manual sync**:
```
End of work:    Close all Claude Code sessions → session-sync push
Other machine:  session-sync pull → Launch Claude Code
```

**Known behavior**: `session-sync push` uses `git add .` to stage all working tree changes.
In 2026-04, a format migration (`UUID.jsonl` → `UUID/subagents/`) caused 35 files to be
bulk-deleted; most had directory versions with no data loss. One-time event.

**Symlink structure** (via `claude-global/` — named to avoid conflict with project-level `.claude/`):
- `claude-global/CLAUDE.md` → `~/.claude/CLAUDE.md`
- `claude-global/settings.json` → `~/.claude/settings.json`
- `claude-global/skills/` → `~/.claude/skills/`
- `claude-global/rules/` → `~/.claude/rules/`
- `claude-global/agents/` → `~/.claude/agents/`

---

## 3. settings.json Design

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
- `block-dotenv.js` (PreToolUse, matcher: `Bash|Read|Grep|Glob`) — blocks `.env` file access.
  Sanitizes git commit messages to avoid false positives
- `workflow-gate.js` (PreToolUse, matcher: `Bash`) — enforces all 7 workflow steps before
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
  sentinel commands (all-or-nothing: any non-sentinel part rejects the whole command)
- `workflow-run-tests.js` (PostToolUse, matcher: `Bash`) — auto-marks `run_tests` based on Bash exit
  code. Detects test runner commands by path pattern (`tests/`) and known runner names. exit 0 →
  `complete`; exit ≠ 0 → `pending` (last-run-wins). Sentinel echoes and read-only commands excluded
- `session-start.js` (SessionStart) — appends `CLAUDE_SESSION_ID=<sid>` to `CLAUDE_ENV_FILE`;
  inherits prior session's workflow steps if cwd+branch match found in transcript (see Session
  ID flow); otherwise creates fresh state; outputs additionalContext with session_id; runs
  zombie cleanup
- `post-compact.js` (PostCompact) — re-injects session_id into conversation context after
  compaction so the transcript retains the marker for future inheritance lookups
- `check-cross-platform.js` (PreToolUse, matcher: `Bash`) — blocks `git commit` when
  platform-specific files (`install/win/` ↔ `install/linux/`) are staged without counterpart
  changes. Skip mechanisms: `.cross-platform-skiplist` (permanent, base tool names) and
  `.git/.cross-platform-reviewed` (one-time, HEAD hash)

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

---

## 4. Test Iteration Workflow

TDD test writing uses a subagent (`mode: "auto"`) to run the write → run → fix loop
autonomously. This reduces user confirmations from O(N) (per-edit approval) to exactly 2:
(a) test case plan approval, (b) final test file review. The subagent is instructed to edit
only test files, never source code. See `write-tests` skill for the procedure.
