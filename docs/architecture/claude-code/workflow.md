# Workflow State Machine

All 14 workflow steps are tracked in a per-session JSON state file and enforced at `git commit`
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
    "workflow_init":        { "status": "complete", "updated_at": "..." },
    "clarify_intent":       { "status": "complete", "updated_at": "..." },
    "research":             { "status": "complete", "updated_at": "..." },
    "outline":              { "status": "skipped",  "updated_at": "..." },
    "detail":               { "status": "complete", "updated_at": "..." },
    "branching_complete":   { "status": "complete", "updated_at": "..." },
    "write_tests":          { "status": "complete", "updated_at": "..." },
    "review_tests":         { "status": "complete", "updated_at": "..." },
    "run_tests":            { "status": "complete", "updated_at": "..." },
    "review_security":      { "status": "skipped",  "updated_at": "..." },
    "docs":                 { "status": "complete", "updated_at": "..." },
    "user_verification":    { "status": "complete", "updated_at": "..." },
    "cleanup":              { "status": "skipped",  "updated_at": "..." },
    "pre_final_report_gate":{ "status": "pending",  "updated_at": "..." }
  }
}
```

`cwd` and `git_branch` are optional (absent in states created before the inheritance feature).
`git_branch` is `null` for non-git directories and detached HEAD.

Statuses: `pending` | `in_progress` | `complete` | `skipped`
- `skipped`: allowed for `research`, `outline`, `detail`, `write_tests`, `review_security`, and `cleanup`
- `user_verification`: cannot be `skipped` — enforced at CLI and permission level
- `branching_complete` and `pre_final_report_gate`: cannot be `skipped`

## Steps and owners

The canonical step order is `VALID_STEPS` in `hooks/lib/workflow-state/state-io.js`. `bin/workflow/next-step --list` renders it with status markers.

| Step | How completed |
|---|---|
| `workflow_init` | `/workflow-init` skill (emits `WORKFLOW_MARK_STEP_workflow_init_complete`) |
| `clarify_intent` | `/clarify-intent` skill (emits `WORKFLOW_CLARIFY_INTENT_COMPLETE`) |
| `research` | `/survey-code` or `/deep-research` (emits `WORKFLOW_MARK_STEP` marker) **or** skipped via `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"` |
| `outline` | `/make-outline-plan` (emits `WORKFLOW_MARK_STEP_outline_complete`) **or** skipped via `echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: <reason>>"` |
| `detail` | `/make-detail-plan` (emits `WORKFLOW_MARK_STEP_detail_complete`) **or** skipped via `echo "<<WORKFLOW_DETAIL_NOT_NEEDED: <reason>>"` |
| `branching_complete` | `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"` after consulting `rules/branch.md` + `rules/worktree.md` |
| `write_tests` | `/write-tests` skill (emits marker) **or** staged `tests/` / `test/` files detected by `workflow-gate.js` **or** skipped via `<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>>` |
| `review_tests` | `/review-tests` skill (emits `WORKFLOW_MARK_STEP_review_tests_complete`) — waived by the same `WORKFLOW_WRITE_TESTS_NOT_NEEDED` sentinel as `write_tests` |
| `run_tests` | `/run-tests` skill (emits sentinel automatically). Direct Bash fallback: `workflow-run-tests.js` PostToolUse hook auto-marks based on exit code. Manual: `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"` |
| `review_security` | `/review-code-security` skill (emits marker) **or** skipped via `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"` |
| `docs` | `/update-docs` skill (emits marker) **or** staged `docs/*.md` / `*.md` files detected by `workflow-gate.js` |
| `user_verification` | `echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"` — triggers `ask` permission dialog; reason mandatory |
| `cleanup` | `/worktree-end` skill (worktree path), branch deletion after PR merge (branch path), or `echo "<<WORKFLOW_MARK_STEP_cleanup_skipped>>"` (main path) |
| `pre_final_report_gate` | `/session-close` skill (emits `WORKFLOW_MARK_STEP_pre_final_report_gate_complete`) |

`write_tests` and `docs` accept evidence-based completion: at commit time, `workflow-gate.js`
checks `git diff --cached --name-only` and treats staged test/doc files as proof of completion,
bypassing the state file entry for those steps. The state file still contains those rows
(created by `session-start.js` with status `pending`); the evidence override happens only in
the gate, not in the file.

`research`, `outline`, `detail`, and `write_tests` can be bypassed with `skipped` status via
their respective `NOT_NEEDED` sentinels (e.g. `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: reason>>"`)
when CLAUDE.md skip conditions are met.

Each skill's `## Completion` section runs `echo "<<WORKFLOW_MARK_STEP_<step>_complete>>"` as
the sole Bash command (no pipes, no `&&`, no redirection). The PostToolUse hook
(`workflow-mark.js`) intercepts this via strict anchored regex on `tool_input.command` and
calls `markStep()` directly using `session_id` from the hook's stdin JSON. This bypasses the
`CLAUDE_ENV_FILE` propagation issue in Bash tool subprocesses (Anthropic bug #27987).

Note: marker format uses `_` as separator (not `:`). Claude Code's permission glob parser
treats `:` as a named-parameter separator inside `Bash(...)` rules, causing silent match
failure (anthropics/claude-code#33601). Using `_` avoids this.

`user_verification` uses a dedicated marker `echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"`
(DQ only, single space, no SQ variant; reason mandatory per #404). This command is in the
`ask` permission category — Claude must request user approval via dialog before the echo
runs. Reason quality is soft-validated: `validateSkipReason` warns but still applies the
state mutation when the reason is a placeholder or too short, so the dialog remains the
binding gate.

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
  calls bin/workflow/next-step --session <sid> (oracle) → injects all 14 step statuses
    + "NEXT ACTION: <oracle NEXT_HINT>" into additionalContext (fail-open)
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

Edit/Write/MultiEdit/editFiles/NotebookEdit attempt → workflow-gate.js (PreToolUse hook, early gate)
  fires only when clarify_intent step is pending or missing
  fail-open: missing session_id, null state, or complete/skipped status → fall through (approve)
  allowlist: Write to ~/.workflow-plans/** by default (configurable via WORKFLOW_PLANS_DIR) is permitted (clarify-intent skill writes intent.md/outline.md/detail.md here)
  blocks otherwise with instructions to invoke /clarify-intent or emit <<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: reason>>
  Read/Grep/Glob/Bash are not in the matcher — they always pass (clarify-intent skill needs them for codebase exploration)

git commit attempt → workflow-gate.js (PreToolUse hook, full gate)
  reads session_id from hook stdin JSON
  WORKFLOW_OFF → approve (early-return; all checks bypassed for this session)
  cross-repo bypass (#1138): resolves the target repo from `git -C <path>` in the command;
    compares git common-dir of the target repo against the agents session repo
    (identified via AGENTS_CONFIG_DIR env or __dirname/../..); if they differ,
    the commit is to a foreign repo — approve without checking agents workflow state.
    Fail-closed: any git error or missing path → treat as same repo → enforce.
  Gate 1 (unstaged-tracked, #269): blocks when tracked files have unstaged working-tree
    modifications. Skipped on `git -c workflow.wip=1` or WORKTREE_OFF marker.
    Fail-open on error (git exec failure); CLI path (bin/check-unstaged-tracked.sh) is fail-safe.
    Detection logic: hasUnstagedTrackedChanges() in hooks/workflow-gate/staged-evidence.js.
  loads ~/.claude/projects/workflow/<session_id>.json
  docs-only short-circuit: if ALL staged files match the human-facing docs allowlist
    (docs/*.md or root README/CHANGELOG/CONTRIBUTING/LICENSE.md),
    only user_verification is checked; all other steps are bypassed
  for write_tests: also checks staged tests/ files (evidence override)
  for docs: also checks staged docs/*.md / *.md files (evidence override)
  cleanup step (#1112): skipped in linked-worktree context (isWorktreeContext → true);
    cleanup is deferred to /worktree-end boundary, not enforced on intermediate commits.
    In main-worktree context (ENFORCE_WORKTREE=off sessions), cleanup blocks until marked.
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

## Oracle-driven sequencing

Step ordering is owned by `bin/workflow/next-step` (the workflow oracle). After each skill completes, the model queries the oracle with:

```
node bin/workflow/next-step --session $CLAUDE_SESSION_ID
```

Output is four `KEY=value` lines: `ACTION` (`invoke|done|blocked|abort`), `NEXT_SKILL`, `NEXT_HINT`, `REASON`. The `NEXT_SKILL` field maps directly to a skill name; non-skill steps (e.g. `branching_complete`, `user_verification`) have an empty `NEXT_SKILL` and a prose `NEXT_HINT` instead.

At the `outline` and `detail` steps only, the oracle appends an optional fifth line `SKIP_HINT` (`WORKFLOW_OUTLINE_NOT_NEEDED` or `WORKFLOW_DETAIL_NOT_NEEDED`) when the session's `intent.md` reads as trivial (a mechanical-change keyword present, no broad-change or new-API-surface signal). It is advisory only — a suggestion that the model may emit the corresponding ask-gated skip sentinel or ignore; the four-line contract is unchanged on every other step. Triviality is judged by `hooks/lib/workflow-state/skip-signal-resolver.js` (`isTrivial`), which fails closed to "not trivial" on any uncertainty.

`--list` mode renders the full 14-step plan with per-step status markers (`[x]` complete, `[-]` skipped, `[*]` current, `[!]` current with missing prereq, `[ ]` pending).

`session-start.js` also calls the oracle on every session start and injects `NEXT ACTION: <hint>` into `additionalContext`, so resumed sessions recover orientation automatically without user action.

## Reset and emergency resume

To roll back to a specific step (e.g. after a crash or to redo a phase):

```
echo "<<WORKFLOW_RESET_FROM_<step>>>"
```

`reset-handler.js` (PostToolUse, via `workflow-mark.js`) marks all prior steps `complete` and resets the target step and all subsequent steps to `pending`. The resulting state is consistent and immediately queryable by the oracle. Use `--list` to verify before proceeding.

Priority order for recovery:
1. **Session resume**: `session-start.js` re-injects oracle verdict automatically — no action needed.
2. **Orientation check**: `node bin/workflow/next-step --session $CLAUDE_SESSION_ID` for an in-session verdict.
3. **RESET_FROM**: when the session needs to redo a phase or state became inconsistent.
4. **Direct JSON edit** (`~/.claude/projects/workflow/<sid>.json`): last resort for surgical per-step changes (e.g. setting one step to `skipped` without affecting others).

## Exemptions

### Read-only config probe from the main worktree

`enforce-worktree.js` blocks all Bash writes from the main worktree, including
`bash -c '...'` (classified as write by the `interpreter-c` pattern). `isAllowedReadOnlyConfigCheck`
in `enforce-worktree.js` adds a narrow exemption for the exact probe shape used
by planning skills to read `CONFIRM_*` flags:

```
bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off KEY on && echo OFF [|| echo ON]'
```

The matcher structurally validates each of the three `&&`-separated clauses and
rejects anything outside this exact shape (no `;`, no `|` outside `||`, no `>`,
no command substitution). **Coupling risk:** the matcher is tied to the literal
probe string. If the skill probe is changed (different key name, different
clause order, different interpreter), the matcher silently re-blocks and the
CONFIRM_* flag is treated as ON. Any future change to the probe string must
update the matcher in lockstep.

The helper's `--is-off` exit code map carries five distinct values (OFF=0, explicit-ON=1, unset-no-default=2, unrecognized-value=3, internal-failure=4); the `&& echo OFF || echo ON` shell idiom maps exit 0 → OFF and all non-zero → ON, so the regex's binary classification is unchanged.

### WIP commit signal (`git -c workflow.wip=1`)

For fixup / intermediate commits between substantive work, `workflow-gate.js`
recognizes the per-command global option:

```
git -c workflow.wip=1 commit -m "..."
```

When detected, the gate skips `user_verification` and Gate 1 (unstaged-tracked
check). All other automated gates (`run_tests`, `review_security`, `docs`) still
fire. The gate does NOT mutate state in the WIP path — `user_verification` remains
`pending`, so the next non-WIP commit re-blocks until the user verifies.

The `-c key=value` form is parsed by `parseGitConfigValues` (in
`hooks/lib/parse-git-args.js`) and only recognized when it appears **before**
the subcommand verb (matching git's own option-parsing semantics). The
`commit-push` skill's `--wip` flag generates this exact form. See
`skills/commit-push/SKILL.md` for usage.

### Final Report

`/session-close` SC-6 emits the Final Report directly into assistant text
using a schema-derived skeleton (`hooks/lib/final-report-schema.renderSkeleton`).
The LLM reads four input files (env JSON, outcome JSON, intent.md, WORKTREE_NOTES.md
backup) and substitutes `<PLACEHOLDER>` tokens. It emits the substituted text
verbatim into its reply, then runs `echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"`.

`stop-final-report-guard.js` blocks the turn if any of the 10 headings from
`getSectionHeadings(sid)` is absent after the last `## Final Report — <sid>` line
in the transcript, or if any unsubstituted `<TOKEN>` remains. Exit 2 + `decision:
block` re-prompts with the specific missing headings or residual tokens listed.

The renderer (`bin/worktree-final-report.js`) was removed in #771. Prior to that,
it emitted a canonical Markdown blob to a Bash tool-result which the LLM pasted
verbatim — a two-step path that permitted LLM semantic rewrites (#626, #700, #765).
