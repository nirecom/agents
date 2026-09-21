# Workflow State Machine

All 16 workflow steps are tracked in a per-session JSON state file and enforced at `git commit`
time by a PreToolUse hook. In order, they are the standard **WF-CODE** plan that
`bin/workflow/next-step --list` renders:

```
 1  workflow_init       Initialize session state and GitHub issue
 2  clarify_intent      Interview and write intent.md
 3  research            Run survey-code and/or deep-research
 4  outline             Propose high-level approaches
 5  detail              File-level implementation plan
 6  branching_complete  Create feature branch and worktree
 7  write_tests         Write tests for planned changes
 8  review_tests        Review test coverage adequacy
 9  write_code          Implement the planned changes
10  run_tests           Run test suite and security review
11  review_security     Adversarial security review and code quality gates
12  docs                Update docs and changelog
13  review_docs         Review doc line limits and README section order
14  user_verification   User verifies the implementation
15  cleanup             Remove worktree and merge branch
16  pre_final_report_gate  Final report and session close
17  final_report        Final report delivered (terminal)
```

**WF-META** sessions (meta-label issues — planning only) auto-skip the implementation steps 7–15;
the per-mode rendering is under [Workflow types](#workflow-types-in-next-step---list) below.

## State file

Path: `~/.claude/projects/workflow/<session-id>.json` (never committed — outside any repo)

Since #1733 the file is an **append-only event stream**. `events` is the only source of
truth (CPR-SSOT); every other field is a derived view folded from it and rewritten on each
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
session ids out of it (`inheritance/lineage.js` harvests them from the current session's own
transcript ancestry — see "Session ID flow" below), so a v1 file may belong to a session still
running an older release that cannot read v2 —
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

### Migration from v2 (schema v3)

The schema version is how a state file **declares what its writer knew**. #1665 inserted
`write_code` into `VALID_STEPS`, and a v2 file written before that has no `write_code` event at
all — the projection defaults the step to `pending` while `run_tests` already stands complete,
which `next-step` would report as an inconsistency and abort on. `migrateV2ToV3` resolves it at
the schema layer instead: when the stream mentions `write_code` in no `step_status` event **and**
at least one step after it in `VALID_STEPS` is settled, it appends a single
`step_status: write_code=complete` with `provenance: "backfilled"`. Sessions that never got that
far gain nothing, and a `write_code` recorded pending on purpose (`RESET_FROM`, `--reset`) is left
untouched — so the `next-step` abort branch still fires for a genuine inconsistency.

`CURRENT_STATE_VERSION` (`state-io/core.js`) is the SSOT for "the newest form this release
writes"; `MAX_KNOWN_STATE_VERSION`, `createInitialState`, and `serializeStateForPersist` all
derive from it. A per-stage migration output version stays a literal in its own stage, because
that is a different fact.

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

#### Zero-commit branches (`base_is_head` and friends)

A branch with zero commits — every change still staged, unstaged, or untracked — resolves
`merge-base HEAD` to `HEAD` itself (#1779/#1331). A `<merge-base>...HEAD` diff range is then
structurally empty even though real work exists, which silently starved both test selection
(`bin/select-tests.sh --auto`) and the Tier 2 semantic match in `skills/run-tests/SKILL.md`
RNT-3 of any input.

`bin/resolve-merge-base.sh --format kv` reports this as data rather than deciding a policy for
it: `base_is_head=true` plus three working-tree counts (`uncommitted_lines`, `uncommitted_files`,
`untracked_files`). The resolver's 5-state trust machinery (`RESOLVED` / `RECORDED` / `SUSPECT`
/ `FALLBACK` / `UNRESOLVED`) is unchanged — these fields are only ever populated once a base has
already been trusted (`RESOLVED`/`RECORDED`), never used to launder a distrusted one. Each
consumer decides what to do with a non-empty working tree on its own terms: `select-tests.sh`
and RNT-3 both fall back to diffing the working tree directly when `base_is_head=true`.
`bin/check-verification-gate.sh` now also reads `base_is_head=true` and calls `degraded_scope_files`
instead of running the zero-diff committed-range path (#1811). Other kv consumers that do not yet
read the field keep their pre-existing behavior — the field is additive, not a breaking change to
the kv contract.

`cwd` and `git_branch` are optional (absent in states created before the inheritance feature).
`git_branch` is `null` for non-git directories and detached HEAD.

Statuses: `pending` | `in_progress` | `complete` | `skipped`
- `skipped`: allowed for the `SKIPPABLE_STEPS` set — `clarify_intent`, `research`, `outline`, `detail`, `write_tests`, `review_tests`, `run_tests`, `review_security`, `review_docs`, and `cleanup`. `run_tests` is admitted only on the docs-only route: both write-side doors (`not-needed-handlers.js`, `mark-step-handler.js`) verify `isDocsOnlyStaged` fail-closed before recording it
- `user_verification`: cannot be `skipped` — enforced at CLI and permission level
- `branching_complete`, `write_code`, and `pre_final_report_gate`: cannot be `skipped`

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

### `complexity_evaluation` (per-stage routing levels, #2099)

Before #2099, one aggregate `level` (`high`/`low`) routed every model-selecting step alike —
a single high-complexity signal sent `detail`, `write_tests`, and `write_code` to opus
together, even when only one of the three actually warranted it. `levels` splits that
verdict per stage so each step routes on its own evidence:

```json
{
  "complexity_evaluation": {
    "level": "high",
    "levels": { "detail": "high", "write_tests": "low", "write_code": "high" },
    "signals": ["S1-multi-file", "S3-security"],
    "recorded_at": "2026-08-20T10:00:00.000Z"
  }
}
```

- **`level`** stays the legacy aggregate (`high` if any signal fires, else `low`) — kept for
  callers that never migrated to per-stage routing.
- **`levels`** keys are exactly `ROUTING_STAGES` (`hooks/workflow-state/complexity-routing.js`:
  `detail`, `write_tests`, `write_code`), each `"high"` or `"low"`. `recordComplexityEvaluation`
  (`state-io/session-fields.js`) derives both `level` and `levels` from the same `signals` input
  in one call, so they can never disagree with each other or be written out of sync.
- **`signals` canonicalization (#2148).** `recordComplexityEvaluation` passes the raw judge
  output through `canonicalizeSignalsForPersistence` before writing: all-recognized input is
  deduplicated and stored verbatim; any unrecognized token collapses the entire array to a single
  `UNRECOGNIZED(<count>)` marker so no verbatim injection text ever reaches persisted state. The
  read CLI (`bin/workflow/read-complexity-evaluation`) re-applies the same canonicalization at
  read time. `readComplexityFacts` (session facts) filters to `SIGNAL_IDS` members only before
  injecting into the WT/WCD prompt, so `UNRECOGNIZED(N)` markers never reach LLM context.
- **Optional field, not a breaking change.** `REQUIRED_FIELDS.complexity_evaluation` in
  `state-io/events.js` stays `["level", "signals"]` — `levels` is validated only when present
  (exact `ROUTING_STAGES` key set, each value `"high"`/`"low"`, or `InvalidEventError`), so
  pre-#2099 events and migration-backfilled events with no `levels` still append cleanly.
- **Read-side compatibility completion.** A missing or malformed `levels` map is not an error
  at read time: `resolveStageLevels` (`skip-signal-resolver/complexity.js`) re-derives all three
  stages from the recorded `level`/`signals` via `deriveLegacyStageLevels`, never partially
  trusting a malformed map. This keeps `readComplexityEvaluation` — the consumer-facing read used
  by `write-tests`/`write-code`'s model-selection step — returning a usable per-stage view even
  for sessions recorded before this event carried `levels` at all.
- **Verification read stays raw.** `readLastRawComplexityEvent` (`state-io/session-fields.js`) is
  read-back verification only — it returns the event's persisted fields with no folding and no
  compatibility completion, so a `levels` that was never written comes back `undefined` rather
  than being silently reconstructed. Never use it on a normal consumer path.

## Steps and owners

The canonical step order is `VALID_STEPS` in `hooks/workflow-state/state-io/core.js` (re-exported by the `state-io.js` barrel). `bin/workflow/next-step --list` renders it with status markers.

| Step | How completed |
|---|---|
| `workflow_init` | `/workflow-init` skill (emits `WORKFLOW_MARK_STEP_workflow_init_complete`) |
| `clarify_intent` | `/clarify-intent` skill (emits `WORKFLOW_CLARIFY_INTENT_COMPLETE`) |
| `research` | `/survey-code` (evidence-based) or `/deep-research` completion, which runs `next-step --advance --step research --complete --next` as its sole Bash command (forward-CLI completion door; sentinel dispatch remains a hook-level recovery fallback) **or** skipped via `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: {reason}>>"` |
| `outline` | `/make-outline-plan` (emits `WORKFLOW_MARK_STEP_outline_complete`) **or** skipped via `echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>"` |
| `detail` | `/make-detail-plan` (emits `WORKFLOW_MARK_STEP_detail_complete`) **or** skipped via `echo "<<WORKFLOW_DETAIL_NOT_NEEDED: {reason}>>"` |
| `branching_complete` | `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: {name}|worktree: {path}|main>>"` after Read of `rules/branch.md` + `rules/worktree.md` (on-demand-only) |
| `write_tests` | `/write-tests` completion runs `next-step --advance --step write_tests --complete --next` as its sole Bash command from the linked worktree CWD (forward-CLI completion door — never prefix with `cd "$AGENTS_CONFIG_DIR" &&`, which breaks the door's own-CWD evidence-repo resolution; sentinel dispatch remains a hook-level recovery fallback) **or** staged `tests/` / `test/` files detected by `workflow-gate.js` **or** skipped via `<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>` |
| `review_tests` | `/review-tests` skill (emits `WORKFLOW_MARK_STEP_review_tests_complete`) — waived by the same `WORKFLOW_WRITE_TESTS_NOT_NEEDED` sentinel as `write_tests` |
| `write_code` | `/write-code` skill — emits `WORKFLOW_MARK_STEP_write_code_in_progress` before its subagent launch and `WORKFLOW_MARK_STEP_write_code_complete` after the post-action review. Not skippable: the implementation body has no not-needed door |
| `run_tests` | `/run-tests` skill (emits sentinel automatically). Direct Bash: `workflow-run-tests.js` PostToolUse hook marks `complete` only from the `RUN_CONTRACT` line that `tests/run-all.sh` emits (provenance + exactly-one contract + `executed>0`, `fail==0`); any other test command demotes `run_tests` to `pending`. Manual: `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"`. **Or** skipped via `echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: {reason}>>"` — accepted only when every staged file is human-facing docs (`isDocsOnlyStaged`); the same fact gates `MARK_STEP_run_tests_skipped` and `next-step --advance --step run_tests --skipped` |
| `review_security` | `/review-code-security` skill (emits marker) **or** skipped via `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: {reason}>>"` |
| `docs` | `/update-docs` skill (emits marker) **or** staged `docs/*.md` / `*.md` files detected by `workflow-gate.js` |
| `review_docs` | `/review-docs` skill (emits `WORKFLOW_MARK_STEP_review_docs_complete`) **or** skipped via `echo "<<WORKFLOW_MARK_STEP_review_docs_skipped>>"` (no approval-gated NOT_NEEDED sentinel — the gates are objective). Evidence-bound: `workflow-gate.js` re-runs `bin/review-doc-gates --staged` on the staged doc blobs every commit and blocks on a HARD failure, even in a docs-only commit |
| `user_verification` | `echo "<<WORKFLOW_USER_VERIFIED: {reason}>>"` — triggers `ask` permission dialog; reason mandatory |
| `cleanup` | `/worktree-end` skill (worktree path), branch deletion after PR merge (branch path), or `echo "<<WORKFLOW_MARK_STEP_cleanup_skipped>>"` (main path) |
| `pre_final_report_gate` | `/session-close` skill (emits `WORKFLOW_MARK_STEP_pre_final_report_gate_complete`) |
| `final_report` | `echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"` after the Final Report is rendered — the sole `TERMINAL_STEPS` member, and the only step the commit gate never enforces |

A failing `/run-tests` re-opens `write_code` together with `run_tests`, and because the masking happens inside `reconcileEffectiveState` the commit gate inherits it: `workflow-gate.js` blocks the commit until the implementation is fixed and the suite is green again (#1665).

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

### Workflow types in `next-step --list`

`bin/workflow/next-step --list` renders the 17-step plan for the session's workflow type.
The standard **WF-CODE** rendering has all 17 steps active — the ordered list at the
[top of this document](#workflow-state-machine).

**WF-META** sessions (meta-label issues — planning only) auto-skip the implementation steps
7–15 per the wf-meta auto-skip stage above:

```
 1  workflow_init       Initialize session state and GitHub issue
 2  clarify_intent      Interview and write intent.md
 3  research            Run survey-code and/or deep-research
 4  outline             Propose high-level approaches
 5  detail              File-level implementation plan
 6  branching_complete  Create feature branch and worktree
[-] 7  write_tests      (auto-skipped)
[-] 8  review_tests     (auto-skipped)
[-] 9  write_code       (auto-skipped)
[-]10  run_tests        (auto-skipped)
[-]11  review_security  (auto-skipped)
[-]12  docs             (auto-skipped)
[-]13  review_docs      (auto-skipped)
[-]14  user_verification  (auto-skipped)
[-]15  cleanup          (auto-skipped)
16  pre_final_report_gate  Final report and session close
17  final_report        Final report delivered (terminal)
```

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

## Runtime and session lifecycle

Session-id resolution, cross-session resume, `next-step`-driven sequencing, reset /
emergency resume, sentinel notation, and the enforcement exemptions are documented in the
runtime half of this state machine: [workflow-runtime.md](workflow-runtime.md).
