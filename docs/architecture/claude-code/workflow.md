# Workflow State Machine

All 15 workflow steps are tracked in a per-session JSON state file and enforced at `git commit`
time by a PreToolUse hook.

## State file

Path: `~/.claude/projects/workflow/<session-id>.json` (never committed — outside any repo)

Since #1733 the file is an **append-only event stream**. `events` is the only source of
truth (CPR-2); every other field is a derived view folded from it and rewritten on each
write. Nothing rewrites history — a step changing status appends an event, it does not
replace one. This is what makes per-step elapsed time computable (`computeIntervals`),
which a keyed map that overwrote `updated_at` in place could never reconstruct.

```json
{
  "version": 2,
  "session_id": "abc123",
  "created_at": "2026-04-12T10:00:00.000Z",
  "session_start_context": { "cwd": "/path/to/project", "git_branch": "main" },
  "workflow_type": "wf-code",
  "events": [
    { "seq": 1, "kind": "step_status", "step": "workflow_init", "status": "complete",
      "at": "2026-04-12T10:00:03.000Z", "provenance": "observed", "origin": "workflow-mark" },
    { "seq": 2, "kind": "step_annotation", "step": "outline", "key": "skip_reason",
      "value": "single obvious approach",
      "at": "2026-04-12T10:04:11.000Z", "provenance": "declared", "origin": "workflow-mark" }
  ],
  "current": {
    "cwd": "/path/to/project",
    "git_branch": "feature/x",
    "steps": {
      "workflow_init": { "status": "complete", "updated_at": "..." },
      "outline":       { "status": "skipped",  "updated_at": "...", "skip_reason": "..." }
    },
    "plan_approvals": { },
    "session_model": null
  },
  "merge_base_baseline": { "base": "<sha>", "branch": "feature/x", "source": "recorded-baseline" }
}
```

`current` is a **cache, not a fact** — it is `projectState(events)` serialized alongside the
stream so a reader needs no fold, and it is discarded and recomputed on every read. Its
legacy `steps` shape is deliberate: every pre-#1733 consumer (`workflow-gate.js`,
`next-step`, `session-start.js`) keeps reading `steps[step].status` unchanged. The key set is
fixed by `PROJECTION_KEYS`; an unknown key aborts the write before a byte is persisted.

### Event vocabulary

| Field | Meaning |
|---|---|
| `seq` | 1-based, gap-free, strictly increasing. A break is corruption, not a repair opportunity — `appendEvents` refuses it and leaves the bytes untouched. |
| `kind` | `step_status`, `step_annotation`, `step_annotations_cleared`, `worktree`, `session_model`, `complexity_evaluation`, `plan_approval`, `plan_approval_revoked`, `reset` |
| `at` | ISO-8601 UTC |
| `provenance` | `observed` (the process saw it happen), `declared` (a caller asserted it), `backfilled` (reconstructed — schema migration or repair) |
| `origin` | which component appended the event |

`provenance` is what lets a consumer distinguish a genuine completion from one reconstructed
by migration or inherited from another session — `effective-state.hasGenuineRecordedComplete`
rejects `backfilled`.

### Reads never write

`readState` normalizes a v1 file **in memory only** and never persists the result. The
workflow directory is shared by every session on the machine, and callers read *foreign*
session ids out of it (`context-scan.js` harvests them from other sessions' transcripts), so
a v1 file may belong to a session still running an older release that cannot read v2 —
migrating it on read would corrupt that session. Bringing a file forward is a **writer's**
job: `writeState`, `updateTopLevel`, and `appendEvents` all normalize under the state lock,
so a file migrates the moment its own session next writes. `persistMigratedState` exists for
callers that want the write explicitly.

`readRawState` throws `CorruptStateFileError` when the file exists but does not parse — that
is evidence, not absence, and the commit gate fails closed on it. A file whose bytes are
unreadable is never overwritten.

### Migration from v1

`migrateV1ToV2` is a pure function of its input — no clock, no randomness, no filesystem — so
two processes migrating the same file agree byte-for-byte and `seq` stays a shared identifier
for the same event. Reconstructed events carry `provenance: "backfilled"`, and those without a
recoverable timestamp additionally carry `at_estimated: true`. It is the one event producer
that does not run through `validateEvent`, so it sanitizes instead: out-of-vocabulary step
keys are dropped and out-of-vocabulary statuses emit nothing (leaving the projection default
`pending`), because a stream the integrity assertion later rejects would wedge the file with
no in-band repair. `started_at` (retired with #1640) is dropped rather than carried.

### `plan_approvals` (approval-gated steps)

`outline` and `detail` carry an approval record, folded from `plan_approval` /
`plan_approval_revoked` events into `current.plan_approvals`:

```json
{
  "plan_approvals": {
    "outline": {
      "source": "confirm-sentinel",
      "reason": "approved approach B",
      "artifact_sha256": "<sha256 of <PLANS_DIR>/<sid>-outline.md>",
      "artifact_hash_status": "recorded",
      "recorded_at": "2026-07-25T10:00:00.000Z"
    }
  }
}
```

Neither step may be persisted `complete` without a valid record. On-disk evidence
(`hasCompletionEvidence`) is necessary but never sufficient: it cannot distinguish
"review not started" from "review finished, user has not approved". Authority lives in
`hooks/workflow-state/completion-approval.js` and is enforced at the `writeState`
boundary, so every caller — hooks, `next-step`, `reconcile-state` — is gated identically.

`source` is a closed set (`SANCTIONED_SOURCES`); an unknown token throws rather than
silently disabling the gate:

| Source | Recorded by | Hash-bound |
|---|---|---|
| `confirm-sentinel` | `<<WORKFLOW_CONFIRM_OUTLINE\|DETAIL: {summary}>>` | yes — a re-edited plan artifact invalidates the approval |
| `confirm-flag-off` | `CONFIRM_OUTLINE=off` / `CONFIRM_DETAIL=off` waiver | no (audit record) |
| `reset-sentinel` | `<<WORKFLOW_RESET_FROM_*>>` re-seeding steps below the reset point | no (audit record) |

Hash checks fail closed: a missing, unreadable, or mismatching artifact is a rejection,
never a downgrade to an existence-only check. A gated step leaving `complete` drops its
record, so a stale approval can never re-validate a later re-completion.

`session_start_context` records where the session began and never changes; `current.cwd` /
`current.git_branch` track where it is now, folded from `worktree` events. `git_branch` is
`null` for non-git directories and detached HEAD.

### `merge_base_baseline` (where this branch started)

Written once, when `branching_complete` is marked — the moment the branch point is still a
fact. Everything downstream (test selection, the quality gates, the Codex review range, the
verification gate) asks `bin/resolve-merge-base.sh` for the base, and the resolver prefers this
record over `origin/main`. That is what #1638 fixed: a fetched `origin/main` can be rewritten,
force-pushed over, or simply stale, so re-deriving the base later gave a different — sometimes
wildly wrong — answer on every call, with no signal that anything had changed.

```json
{
  "merge_base_baseline": {
    "recorded_at": "2026-07-30T10:00:00.000Z",
    "base": "<sha of HEAD at branching time>",
    "branch": "feature/x",
    "branch_head": "<sha>",
    "repo_root": "/path/to/worktree",
    "source": "recorded-baseline",
    "head_committed_at": "2026-07-30T09:58:00.000Z",
    "session_created_at": "2026-07-30T09:30:00.000Z",
    "post_session_head": false,
    "alt_base": "<sha or null>",
    "approved_reason": null
  }
}
```

Ownership rules, all enforced in `hooks/workflow-state/merge-base-baseline.js`:

- **`base` is always `git rev-parse HEAD`,** never a merge-base against a remote. A
  remote-derived value is the stale guess the record exists to replace.
- **One automatic writer,** `hooks/workflow-mark/branching-handler.js`, write-once. A
  re-emitted `BRANCHING_COMPLETE` does not move a base that later steps already scoped by.
  Failure to record is a warning, never fatal — a lost baseline degrades to guessing, which is
  what every consumer did before.
- **One override,** `bin/workflow/record-merge-base-baseline`, reached only after the user has
  confirmed the base. `--reason` is mandatory, the sha is verified to resolve and to be an
  ancestor of `HEAD`, and the record keeps `source: "user-approved"` plus `approved_reason` so
  the decision stays auditable. This is the recovery path from a `SUSPECT` verdict.
- **`post_session_head` and `alt_base` are evidence, not decisions.** They let a consumer say
  "the recorded base may be behind your HEAD, here is the alternative" without any code
  silently adopting the alternative.

The resolver re-verifies identity before adopting the record (current branch matches, and both
`branch_head` and `base` are ancestors of `HEAD`); a record that fails any check is demoted and
reported, never used. `repo_root` is informational and deliberately excluded from that check —
the same worktree is legitimately spelled several ways on Windows.

Statuses: `pending` | `in_progress` | `complete` | `skipped`
- `skipped`: allowed for the `SKIPPABLE_STEPS` set — `clarify_intent`, `research`, `outline`, `detail`, `write_tests`, `review_tests`, `review_security`, and `cleanup`
- `user_verification`: cannot be `skipped` — enforced at CLI and permission level
- `branching_complete` and `pre_final_report_gate`: cannot be `skipped`

**`skip_verdict` field (outline/detail only):** When a speculative skip is recorded
(`WORKFLOW_OUTLINE_NOT_NEEDED` / `WORKFLOW_DETAIL_NOT_NEEDED`), a `skip_verdict` object is
folded into the step's own entry as a step annotation:

```json
{
  "current": {
    "steps": {
      "outline": {
        "status": "skipped",
        "updated_at": "2026-07-15T10:00:00.000Z",
        "skip_reason": "single obvious approach",
        "skip_verdict": { "verdict": "pending", "recorded_at": "2026-07-15T10:00:00.000Z" }
      }
    }
  }
}
```

`verdict` is `pending` (skip-verifier not yet run), `approve` (skip confirmed safe), or
`veto` (skip rejected — step must run). A `veto` verdict de-skips the step at read time:
`reconcileEffectiveState` treats a step whose raw status is `skipped` but whose
`skip_verdict.verdict === "veto"` as `pending`, forcing `next-step` to schedule it.
A `pending` verdict blocks next-step with a `"skip_verdict_pending"` hint until the
verifier resolves.

## Steps and owners

The canonical step order is `VALID_STEPS` in `hooks/workflow-state/state-io/core.js` (re-exported by the `state-io.js` barrel). `bin/workflow/next-step --list` renders it with status markers.

| Step | How completed |
|---|---|
| `workflow_init` | `/workflow-init` skill (emits `WORKFLOW_MARK_STEP_workflow_init_complete`) |
| `clarify_intent` | `/clarify-intent` skill (emits `WORKFLOW_CLARIFY_INTENT_COMPLETE`) |
| `research` | `/survey-code` or `/deep-research` (emits `WORKFLOW_MARK_STEP` marker) **or** skipped via `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: {reason}>>"` |
| `outline` | `/make-outline-plan` (emits `WORKFLOW_MARK_STEP_outline_complete`) **or** skipped via `echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>"` |
| `detail` | `/make-detail-plan` (emits `WORKFLOW_MARK_STEP_detail_complete`) **or** skipped via `echo "<<WORKFLOW_DETAIL_NOT_NEEDED: {reason}>>"` |
| `branching_complete` | `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: {name}|worktree: {path}|main>>"` after consulting `rules/branch.md` + `rules/worktree.md` |
| `write_tests` | `/write-tests` skill (emits marker) **or** staged `tests/` / `test/` files detected by `workflow-gate.js` **or** skipped via `<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>` |
| `review_tests` | `/review-tests` skill (emits `WORKFLOW_MARK_STEP_review_tests_complete`) — waived by the same `WORKFLOW_WRITE_TESTS_NOT_NEEDED` sentinel as `write_tests` |
| `run_tests` | `/run-tests` skill (emits sentinel automatically). Direct Bash: `workflow-run-tests.js` PostToolUse hook marks `complete` only from the `RUN_CONTRACT` line that `tests/run-all.sh` emits (provenance + exactly-one contract + `executed>0`, `fail==0`); any other test command demotes `run_tests` to `pending`. Manual: `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"` |
| `review_security` | `/review-code-security` skill (emits marker) **or** skipped via `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: {reason}>>"` |
| `docs` | `/update-docs` skill (emits marker) **or** staged `docs/*.md` / `*.md` files detected by `workflow-gate.js` |
| `user_verification` | `echo "<<WORKFLOW_USER_VERIFIED: {reason}>>"` — triggers `ask` permission dialog; reason mandatory |
| `cleanup` | `/worktree-end` skill (worktree path), branch deletion after PR merge (branch path), or `echo "<<WORKFLOW_MARK_STEP_cleanup_skipped>>"` (main path) |
| `pre_final_report_gate` | `/session-close` skill (emits `WORKFLOW_MARK_STEP_pre_final_report_gate_complete`) |
| `final_report` | `echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"` after the Final Report is rendered — the sole `TERMINAL_STEPS` member, and the only step the commit gate never enforces |

`write_tests` and `docs` accept evidence-based completion: at commit time, `workflow-gate.js`
checks `git diff --cached --name-only` and treats staged test/doc files as proof of completion,
bypassing the state file entry for those steps. The state file still contains those rows
(created by `session-start.js` with status `pending`); the evidence override happens only in
the gate, not in the file.

**Effective state derivation (Approach B):** Every consumer — `workflow-gate.js`, `bin/workflow/next-step`, `session-start.js` — reads the *effective* (derived) step status via `reconcileEffectiveState(state, sessionId, opts)` in `hooks/lib/workflow-state/effective-state.js`, not the raw JSON record directly. The function applies four derivation stages without writing anything back to disk:

1. **wf-meta auto-skip** — non-applicable WF-CODE steps are treated as `skipped`.
2. **skip_verdict gate** — outline/detail steps with a pending or vetoed `skip_verdict` are held at `pending`/`skipped` accordingly (see `skip_verdict` field above).
3. **Post-veto reset** — when outline or detail is veto-de-skipped, downstream steps that were `complete` in the raw record are treated as `pending` until the plan is re-approved.
4. **Evidence + approval resolution** — for `pending` steps in `EVIDENCE_STEPS`, `hasCompletionEvidence()` is checked; for approval-gated steps (`outline`, `detail`), `evaluateCompletionApproval()` is also checked. Only when both pass is the effective status `complete`. This derivation is read-only and does not mutate the state file.

`clarify_intent`, `outline`, `detail`, and `write_tests` also accept evidence-based **next-step auto-repair**: when `next-step` finds one of these steps `pending` in the effective view, evidence already resolves it to `complete` inside the snapshot — no write-back occurs (Approach B). This resolves compaction gaps where the step completed but the marker was lost.

`research`, `outline`, `detail`, and `write_tests` can be bypassed with `skipped` status via
their respective `NOT_NEEDED` sentinels (e.g. `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: {reason}>>"`)
when CLAUDE.md skip conditions are met.

Each skill's `## Completion` section runs `echo "<<WORKFLOW_MARK_STEP_<step>_complete>>"` as
the sole Bash command (no pipes, no `&&`, no redirection). The PostToolUse hook
(`workflow-mark.js`) intercepts this via strict anchored regex on `tool_input.command` and
calls `markStep()` directly using `session_id` from the hook's stdin JSON. This bypasses the
`CLAUDE_ENV_FILE` propagation issue in Bash tool subprocesses (Anthropic bug #27987).

Note: marker format uses `_` as separator (not `:`). Claude Code's permission glob parser
treats `:` as a named-parameter separator inside `Bash(...)` rules, causing silent match
failure (anthropics/claude-code#33601). Using `_` avoids this.

`user_verification` uses a dedicated marker `echo "<<WORKFLOW_USER_VERIFIED: {reason}>>"`
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
        (all-pending guard: a session whose every step is pending was abandoned
         before doing any real work — inheriting it would overwrite a genuine
         in-progress session's state; skip and try the next collected ID — #1305)
      if user_verification=complete: stop trying this JSONL (task done, start fresh)
      else: copies matching session's steps (state inheritance)
    if no match found in any transcript: creates fresh state with all steps pending
  writes ~/.claude/projects/workflow/<sid>.json (includes cwd, git_branch)
  calls bin/workflow/next-step --session <sid> → injects all 15 step statuses
    + "NEXT ACTION: <next-step NEXT_HINT>" into additionalContext (fail-open)
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
  Gate 2 (code-size HARD limit, #1701): runs `bash bin/review-code-size --staged` against the
    staged index and blocks when any staged code file exceeds the 500-line HARD limit
    (rules/coding/file-split.md). The script owns thresholds and line counting (CPR-2);
    the hook only maps exit 1 → block. Line counts come from the staged blob
    (`git show :<file>`), not the working tree, so the commit that performs a split passes.
    Not skipped by the docs-only short-circuit, `workflow.wip=1`, or WORKTREE_OFF —
    only WORKFLOW_OFF bypasses it (early return). Fails closed on infrastructure errors
    (AGENTS_CONFIG_DIR unresolved, script missing, bash not on PATH, unexpected exit code);
    fails open only on the 3s spawn timeout.
    Implementation: checkCodeSizeHardLimit() in hooks/workflow-gate/code-size-gate.js.
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

### Bash/CLI-side resolution

Hooks receive `session_id` via hook stdin JSON, but bash scripts and standalone Node CLIs have
no such channel. They all resolve through one canonical implementation:
`hooks/workflow-state/session-id.js` (`resolveSessionId()`) — a 7-step chain: hook ctx input →
`CLAUDE_CODE_SESSION_ID` → `CLAUDE_ENV_FILE` → `CLAUDE_SESSION_ID` → `ctx.transcriptPath` →
`WORKTREE_NOTES.md` → JSONL mtime scan (gated by an `isSameGitRepo` cross-repo guard). Bash
callers reach it via the `bin/resolve-session-id` bridge (stdout = sid, exit 2 when
unresolvable); Node CLIs `require()` it directly. Callers locate the bridge relative to their
own file (`BASH_SOURCE` / `__dirname`), never via `$AGENTS_CONFIG_DIR`, so every checkout uses
its own resolver even when that env var points at a different checkout. Why one SSOT: eight
independent resolver implementations diverged over time and produced concurrent-session
misattribution (#1082); consolidation (#1251) removes the divergence class instead of patching
members one at a time.

## Fail-safe behavior

| Condition | Result |
|---|---|
| `session_id` missing from hook stdin | block |
| State file not found | block |
| State file corrupted (bad JSON) | block |
| Step `pending` or `in_progress` | block |
| Non-skippable step marked `skipped` | block |

## next-step-driven sequencing

Step ordering is owned by `bin/workflow/next-step`. That file is a dispatcher only — the implementation lives in `bin/workflow/lib/next-step/` (`cli.js`, `steps.js`, `repo-dir.js`, `entrypoint-path.js`, `list.js`, `state-ops.js`, `verdict.js`). After each skill completes, the model queries next-step with:

```
node bin/workflow/next-step --session $CLAUDE_SESSION_ID
```

Output is four `KEY=value` lines: `ACTION` (`invoke|done|blocked|abort`), `NEXT_SKILL`, `NEXT_HINT`, `REASON`. The `NEXT_SKILL` field maps directly to a skill name; non-skill steps (e.g. `branching_complete`, `user_verification`) have an empty `NEXT_SKILL` and a prose `NEXT_HINT` instead.

At the `outline` and `detail` steps only, next-step first checks for an authoritative recorded-verdict skip (#1286): when the orchestrator has recorded a valid `skip_judgment` for the step (`judgment_source` = `orchestrator`, all conditions met), next-step marks the step `skipped` directly and advances — no advisory line, no user-emitted sentinel. The record is written by `bin/workflow/record-skip-judgment` and validated by `hooks/workflow-state/skip-signal-resolver.js` (`hasValidSkipJudgment`). If `markStep` fails to persist the skip, next-step falls through to normal step handling instead of re-entering the skip branch — this guards against unbounded recursion when the mark cannot be written.

Absent a recorded verdict, next-step appends an optional fifth line `SKIP_HINT` (`WORKFLOW_OUTLINE_NOT_NEEDED` or `WORKFLOW_DETAIL_NOT_NEEDED`) when the session's `intent.md` reads as trivial (a mechanical-change keyword present, no broad-change or new-API-surface signal). This is a weak supplementary hint (demoted from sole gate by #1286) — advisory only, which the model may act on by emitting the corresponding ask-gated skip sentinel or ignore; the four-line contract is unchanged on every other step. Triviality is judged by the same resolver's `isTrivial`, which fails closed to "not trivial" on any uncertainty.

`--list` mode renders the full 15-step plan with per-step status markers (`[x]` complete, `[-]` skipped, `[*]` current, `[!]` current with missing prereq, `[ ]` pending).

`session-start.js` also calls next-step on every session start and injects `NEXT ACTION: <hint>` into `additionalContext`, so resumed sessions recover orientation automatically without user action.

## Reset and emergency resume

To roll back to a specific step (e.g. after a crash or to redo a phase):

```
echo "<<WORKFLOW_RESET_FROM_{step}: {reason}>>"
```

Example: `echo "<<WORKFLOW_RESET_FROM_write_tests: user requested re-plan>>"`

`reset-handler.js` (PostToolUse, via `workflow-mark.js`) marks all prior steps `complete` and resets the target step and all subsequent steps to `pending`. The resulting state is consistent and immediately queryable by next-step. Use `--list` to verify before proceeding.

Priority order for recovery:
1. **Session resume**: `session-start.js` re-injects next-step verdict automatically — no action needed.
2. **Orientation check**: `node bin/workflow/next-step --session $CLAUDE_SESSION_ID` for an in-session verdict.
3. **Auto-repair**: next-step calls `hasCompletionEvidence()` for evidence-backed steps and self-corrects — no action needed.
4. **`--mark <step> complete`**: `node bin/workflow/next-step --session $CLAUDE_SESSION_ID --mark <step> complete` marks one step complete without touching others (session-global; run from any directory). Use when next-step's scoped hint names a specific step to mark.
5. **RESET_FROM**: when the session needs to redo a phase or state became inconsistent.
6. **Direct JSON edit** (`~/.claude/projects/workflow/<sid>.json`): last resort for surgical per-step changes (e.g. setting one step to `skipped` without affecting others).

## Sentinel notation

The `<< >>` frame has no strong positive rationale — it was an implementation choice when
echo-based markers replaced the `mark-step.js` CLI (2026-04-13, Anthropic bug #27987 workaround).
The functional requirements it satisfies are: (1) a fixed literal matchable by `settings.json`
permission globs, (2) distinctive enough not to collide with unrelated `echo` commands, and
(3) parseable by an anchored strict regex in the PostToolUse hook. Any frame meeting these
would work; changing it now is not worth the migration cost across regexes, permission rules,
and docs. The original `:` field separator was replaced by `_` because the permission glob
parser treats `:` specially (claude-code#33601).

Placeholder notation in sentinel templates uses braces — `{step}`, `{reason}` — never
`<angle brackets>`: a `<reason>` placeholder followed by the `>>` frame closer produces a
`>>>` run whose bracket count is routinely miscopied.

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

Gate 2 (code-size HARD limit) also continues to fire for WIP commits — a WIP
commit must not be able to land a file that exceeds the 500-line HARD limit.

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

That guard is trigger-dependent: it only ran when `/session-close` had already
written the Final Report env file, so a session that never ran the close procedure
produced no report *and* no block. Re-verifying #771 against that gap confirmed the
renderer stays removed (reinstating it would restore the paste-and-rewrite path it
was deleted for); the fix belongs in the trigger instead. `stop-final-report-guard.js`
therefore carries a second lane: when the env file is absent but `bin/workflow/next-step`
reports the session has reached `pre_final_report_gate`, the turn is blocked as
"close procedure not run". Three escape hatches keep it from trapping a session:
`WORKFLOW_OFF` for the session, a session-close gate artifact whose `gate_action` is
`yield` (the supervisor deliberately handed the turn back), and any failure to consult
next-step at all (fail-open). `stop-premature-stop-guard.js` yields the same condition
to this lane so the two guards never both speak.
