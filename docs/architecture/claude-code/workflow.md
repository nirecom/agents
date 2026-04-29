# Workflow State Machine

All 10 workflow steps are tracked in a per-session JSON state file and enforced at `git commit`
time by a PreToolUse hook.

## State file

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
    "user_verification": { "status": "complete", "updated_at": "..." },
    "cleanup":           { "status": "skipped",  "updated_at": "..." }
  }
}
```

`cwd` and `git_branch` are optional (absent in states created before the inheritance feature).
`git_branch` is `null` for non-git directories and detached HEAD.

Statuses: `pending` | `in_progress` | `complete` | `skipped`
- `skipped`: allowed for `research`, `plan`, `write_tests`, `review_security`, and `cleanup`
- `user_verification`: cannot be `skipped` — enforced at CLI and permission level

## Steps and owners

| Step | How completed |
|---|---|
| `clarify_intent` | `/clarify-intent` skill (emits `WORKFLOW_CLARIFY_INTENT_COMPLETE` marker) |
| `research` | `/survey-code` or `/deep-research` skill (emits `WORKFLOW_MARK_STEP` marker) **or** skipped via `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"` |
| `plan` | `/make-outline-plan` → `/make-detail-plan` (2-stage pipeline; marker emitted by `make-detail-plan`) |
| `branching_decision` | `echo "<<WORKFLOW_BRANCHING_DECIDED: <decision>>"` after consulting `rules/branch.md` and `rules/worktree.md` |
| `write_tests` | `/write-tests` skill (emits marker) **or** staged `tests/` / `test/` files detected by `workflow-gate.js` |
| `run_tests` | PostToolUse hook (`workflow-run-tests.js`) auto-marks based on Bash exit code when command touches `tests/` or invokes a test runner. Manual fallback: `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"` |
| `review_security` | `/review-code-security` skill (emits `WORKFLOW_MARK_STEP` marker) **or** skipped via `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"` |
| `docs` | `/update-docs` skill (emits marker) **or** staged `docs/*.md` / `*.md` files detected by `workflow-gate.js` |
| `user_verification` | `echo "<<WORKFLOW_USER_VERIFIED>>"` — triggers `ask` permission dialog; user must approve |
| `cleanup` | `/worktree-end` skill (worktree path), or branch deletion after PR merge (branch path), or `echo "<<WORKFLOW_MARK_STEP_cleanup_skipped>>"` (main path) |

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

## Session ID flow

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

Skill runs (/clarify-intent, /make-outline-plan, /make-detail-plan, /write-tests, etc.)
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

## Fail-safe behavior

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
