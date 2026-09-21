# Workflow Runtime & Session Lifecycle

The runtime half of the workflow state machine: session-id resolution, cross-session resume,
next-step sequencing, reset / emergency resume, sentinel notation, and the enforcement
exemptions. The persisted state data model and the 17-step catalog live in
[workflow.md](workflow.md).

## Session ID flow

```
Session start → session-start.js (SessionStart hook)
  appends CLAUDE_SESSION_ID=<sid> to CLAUDE_ENV_FILE
  if state file does not exist:
    resolveInheritanceDonor({sessionId, source, transcriptPath, ctx, agentId}) (#1305):
      Gate A (subagent exclusion): agentId present → no auto-inherit
      Gate B (source gate): source must be "resume" or "compact" to auto-inherit;
        "startup" → non-blocking "startup-no-lineage" outcome (no scan, no candidate offer);
        "clear" / unknown source → "source-gated" (no auto-inherit)
      Gate C (readLineageAncestors, hooks/workflow-state/inheritance/lineage.js):
        reads the CURRENT transcript only (no cwd+branch directory scan — the
        #1305 bug's root cause) for entries carrying forkedFrom.sessionId or a
        copied SessionStart/PostCompact "Current workflow session_id: <sid>"
        announce line; returns ancestors nearest-first, de-duplicated, self-excluded
      Gate D (nearest-ancestor-decides): the FIRST ancestor with a state file is
        the sole decision-maker — no falling through to an older ancestor when the
        nearest one is ineligible (this fixes the original ancestor-passthrough bug;
        under the old cwd+branch scan, skipping an ineligible candidate and trying
        the next one let evidence-free sessions inherit through it)
      Gate E (contextMatches): the donor's cwd/branch must match the heir's —
        necessary-condition sanity check, not the primary key
      Gate F (evaluateResumability): all-pending donor → not resumable
        (a session whose every step is pending was abandoned before doing any
         real work — inheriting it would overwrite a genuine in-progress
         session's state); user_verification=complete → not resumable (task
         done, start fresh)
    ancestor passes all gates → copies its steps (state inheritance)
    no ancestor / gate failure: session starts fresh; a same-cwd+branch candidate
      that failed only on lineage (no provable descent) is offered via the
      explicit adoption path below, never auto-inherited
    if no match found: creates fresh state with all steps pending
  writes ~/.claude/projects/workflow/<sid>.json (includes cwd, git_branch)
  calls bin/workflow/next-step --session <sid> → injects all 17 step statuses
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
  allowlist (hooks/workflow-gate/early-gate-allowlist.js, #2108): two destinations, applied
    identically at Tier 1 (workflow_init) and Tier 2 (clarify_intent) —
      the plans dir ~/.workflow-plans/** (configurable via WORKFLOW_PLANS_DIR; clarify-intent
        writes intent.md/outline.md/detail.md here), and
      the session scratchpad dir (same predicate the settings.md scratchpad allow uses)
    Both sit outside the repo and outside workflow state, so a write there cannot pre-empt
    the routing the gate protects — while a gate with no legal write target leaves a
    subagent nothing to do but hunt for a bypass.
  blocks otherwise with instructions to invoke /clarify-intent or emit <<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: reason>>
  the VERDICT never branches on caller identity — only the REMEDY does
    (hooks/workflow-gate/early-gate-messages.js): a subagent cannot run a skill or emit a
    workflow sentinel, so its block reason carries neither, and instead names the allowed
    write targets and tells it to report back to the main conversation
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
    (rules/coding/file-split.md). The script owns thresholds and line counting (CPR-SSOT);
    the hook only maps exit 1 → block. Line counts come from the staged blob
    (`git show :<file>`), not the working tree, so the commit that performs a split passes.
    Not skipped by the docs-only short-circuit, `workflow.wip=1`, or WORKTREE_OFF —
    only WORKFLOW_OFF bypasses it (early return). Fails closed on infrastructure errors
    (AGENTS_CONFIG_DIR unresolved, script missing, bash not on PATH, unexpected exit code);
    fails open only on the 3s spawn timeout.
    Implementation: checkCodeSizeHardLimit() in hooks/workflow-gate/code-size-gate.js.
  loads ~/.claude/projects/workflow/<session_id>.json
  docs-only short-circuit: if ALL staged files match the human-facing docs allowlist,
    only user_verification is checked; all other steps are bypassed.
    Behaviour/prompt files are deliberately outside the allowlist even when they are
    .md (root CLAUDE.md, any SKILL.md, subdirectory README.md) — editing them changes
    behaviour, so they take the full workflow.
    Allowlist SSOT: DOCS_ONLY_ALLOWLIST in hooks/workflow-gate/staged-evidence.js,
    surfaced to scripts by bin/is-docs-only. Not restated here.
  for write_tests: also checks staged tests/ files (evidence override)
  for docs: also checks staged docs/*.md / *.md files (evidence override)
  cleanup step (#1112): skipped in linked-worktree context (isWorktreeContext → true);
    cleanup is deferred to /worktree-end boundary, not enforced on intermediate commits.
    In main-worktree context (ENFORCE_WORKTREE=off sessions), cleanup blocks until marked.
  approves if all steps complete/skipped; blocks with remediation message otherwise
```

State inheritance is keyed on provable transcript descent (lineage), not on cwd+branch alone
(#1305) — cwd+branch (`contextMatches`) is a necessary condition checked after lineage, never
the primary key. The practical inheritance window is 7 days (zombie cleanup limit). Non-git
directories and detached HEAD both use `git_branch: null` — they match each other but not
named branches. Completed workflows (`user_verification: complete`) are never inherited — the
ancestor is treated as not-resumable so the new session starts fresh.

A session that loses its own id outright (a true process crash, with no `forkedFrom` /
announce-line evidence to prove descent) cannot auto-inherit — nothing in its fresh transcript
can prove where it came from. That case is served by explicit, user-approved adoption instead:
`bin/workflow/adopt-session-state --session <heir-sid> --from <donor-sid>` (or the
`/workflow-init` `adopt-prior-state` phase, same underlying implementation in
`hooks/workflow-state/inheritance/adopt.js` — CPR-SSOT, one execution point for both routes).
Adoption re-runs the same guards as automatic inheritance (heir must be untouched/all-pending,
donor context must match, donor must be resumable) — being named on a command line is not
itself evidence.

### Bash/CLI-side resolution

Hooks receive `session_id` via hook stdin JSON, but bash scripts and standalone Node CLIs have
no such channel. They all resolve through one canonical implementation:
`hooks/workflow-state/session-id.js` (`resolveSessionId()`) — a strict 4-tier SUPPLY-only chain:
`ctx.sessionIdFromInput` → `CLAUDE_CODE_SESSION_ID` → `CLAUDE_SESSION_ID` →
`ctx.transcriptPath` basename. Every tier comes from the calling process's own context; no tier
infers an id from filesystem traces (the former `CLAUDE_ENV_FILE` / `WORKTREE_NOTES.md` /
JSONL-mtime-scan inference tiers were removed — #2270). Bash callers reach it via the
`bin/resolve-session-id` bridge (stdout = sid on rc 0; rc 2 = unresolvable, the only "no
session" code; rc 3 = the resolver itself faulted, a distinct condition callers must not
conflate with "no session" — full rc table: [session-id-resolution.md](session-id-resolution.md#the-bridge-rc-contract));
Node CLIs `require()` it directly. Callers locate the bridge relative to their own file
(`BASH_SOURCE` / `__dirname`), never via `$AGENTS_CONFIG_DIR`, so every checkout uses its own
resolver even when that env var points at a different checkout. Why one SSOT: eight independent
resolver implementations diverged over time and produced concurrent-session misattribution
(#1082); consolidation (#1251) removes the divergence class instead of patching members one at
a time.

`resolveSessionId()` answers "which session am *I*?" and nothing else — never repurpose it to
name an upstream session a cross-session command was pointed at. `/resume-session --from` passes
that id explicitly, and `bin/workflow/lib/next-step/repo-dir-guard.js` distinguishes the two by
value (`sid !== resolveSessionId({})`), not by whether a `--session` flag was present. That
distinction gates the guard's INDETERMINATE verdict at the worktree-end → session-close boundary:
when the worktree directory has been deleted, only a self-call fails open so session-close can
proceed; an explicit cross-session override fails fast instead of silently fail-open (#2316).

Identifier-family boundaries, why filesystem inference was removed from the chain, the bridge
rc contract, and the static guard against bypassing the resolver:
[session-id-resolution.md](session-id-resolution.md).

## Cross-session resume

A session can inherit from an upstream session it has no transcript lineage to, via
`/resume-session --from <sid>` (`bin/lib/resume-session/`). Two facts govern what survives:

- **Step context-dependence** — whether a step's completion evidence lives in the worktree or in
  the session's own record. `hooks/workflow-state/state-io/step-context-class.js` owns the
  classification for all 17 steps; `granularity: "context-independent-only"` inherits only the
  latter set, `"full"` inherits everything.
- **Evidence class** — what the upstream actually left behind. The state file (7-day TTL) and the
  handoff artifact (no TTL) expire independently, so availability degrades through
  `state-and-artifacts` → `state-only` → `artifacts-only` → `none` rather than failing outright.
  The artifact contract is in
  [handoff-artifact.md](handoff-artifact.md).

## Fail-safe behavior

| Condition | Result |
|---|---|
| `session_id` missing from hook stdin | block |
| State file not found | block |
| State file corrupted (bad JSON) | block |
| Step `pending` or `in_progress` | block |
| Non-skippable step marked `skipped` | block |
| `toolInput.cwd` null / non-string (e.g. VS Code extension) | resolve via `process.cwd()` (`hooks/lib/resolve-cwd.js` `resolveInputCwd`), not block (#2319) |

## next-step-driven sequencing

Step ordering is owned by `bin/workflow/next-step`. That file is a dispatcher only — the implementation lives in `bin/workflow/lib/next-step/` (`cli.js`, `steps.js`, `repo-dir.js`, `entrypoint-path.js`, `list.js`, `state-ops.js`, `verdict.js`). After each skill completes, the model queries next-step with:

```
node bin/workflow/next-step --session $CLAUDE_SESSION_ID
```

Output is four `KEY=value` lines: `ACTION` (`invoke|done|blocked|abort`), `NEXT_SKILL`, `NEXT_HINT`, `REASON`. The `NEXT_SKILL` field maps directly to a skill name; non-skill steps (e.g. `branching_complete`, `user_verification`) have an empty `NEXT_SKILL` and a prose `NEXT_HINT` instead.

At the `outline` and `detail` steps only, next-step first checks for an authoritative recorded-verdict skip (#1286): when the orchestrator has recorded a valid `skip_judgment` for the step (`judgment_source` = `orchestrator`, all conditions met), next-step marks the step `skipped` directly and advances — no advisory line, no user-emitted sentinel. The record is written by `bin/workflow/record-skip-judgment` and validated by `hooks/workflow-state/skip-signal-resolver.js` (`hasValidSkipJudgment`). If `markStep` fails to persist the skip, next-step falls through to normal step handling instead of re-entering the skip branch — this guards against unbounded recursion when the mark cannot be written.

Absent a recorded verdict, next-step appends an optional fifth line `SKIP_HINT` (`WORKFLOW_OUTLINE_NOT_NEEDED` or `WORKFLOW_DETAIL_NOT_NEEDED`) when the session's `intent.md` reads as trivial (a mechanical-change keyword present, no broad-change or new-API-surface signal). This is a weak supplementary hint (demoted from sole gate by #1286) — advisory only, which the model may act on by emitting the corresponding ask-gated skip sentinel or ignore; the four-line contract is unchanged on every other step. Triviality is judged by the same resolver's `isTrivial`, which fails closed to "not trivial" on any uncertainty.

`--list` mode renders the full 17-step plan with per-step status markers (`[x]` complete, `[-]` skipped, `[*]` current, `[!]` current with missing prereq, `[ ]` pending).

`session-start.js` also calls next-step on every session start and injects `NEXT ACTION: <hint>` into `additionalContext`, so resumed sessions recover orientation automatically without user action.

## Reset and emergency resume

To roll back to a specific step (e.g. after a crash or to redo a phase):

```
echo "<<WORKFLOW_RESET_FROM_{step}: {reason}>>"
```

Example: `echo "<<WORKFLOW_RESET_FROM_write_tests: user requested re-plan>>"`

`{step}` is any `VALID_STEPS` member, so `WORKFLOW_RESET_FROM_write_code` became valid when `write_code` joined the vocabulary (#1665).

`reset-handler.js` (PostToolUse, via `workflow-mark.js`) marks all prior steps `complete` and resets the target step and all subsequent steps to `pending`. The resulting state is consistent and immediately queryable by next-step. Use `--list` to verify before proceeding.

Priority order for recovery:
1. **Session resume**: `session-start.js` re-injects next-step verdict automatically — no action needed.
2. **Orientation check**: `node bin/workflow/next-step --session $CLAUDE_SESSION_ID` for an in-session verdict.
3. **Auto-repair**: next-step calls `hasCompletionEvidence()` for evidence-backed steps and self-corrects — no action needed.
4. **`--mark <step>`**: `node bin/workflow/next-step --session $CLAUDE_SESSION_ID --mark <step>` marks one step complete without touching others (session-global; run from any directory). Use when next-step's scoped hint names a specific step to mark.
5. **RESET_FROM**: when the session needs to redo a phase or state became inconsistent.
6. **Direct JSON edit** (`~/.claude/projects/workflow/<sid>.json`): last resort for surgical per-step changes (e.g. setting one step to `skipped` without affecting others).

Argv note (#1947): the settling status is passed as a value-less flag — `--complete` / `--skipped` / `--pending` on `--advance`, and no trailing token at all on `--mark`. A bare `complete` argv token is misread as the bash builtin by the worktree-isolation command classifier, which blocks the whole call. The old `--status <value>` spelling, and the trailing status token on `--mark`, still work and warn on stderr; the persisted status strings are unchanged.

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

### Adoption-origin allow-list (`ADOPTION_ORIGINS`, #1794)

`hooks/workflow-state/lifecycle.js` (`hasSelfRecordedStepSettlement` /
`isWorkflowStarted`) answers "did THIS session genuinely start the workflow
itself?" for the C4 premature-stop guard, the C2 supervisor scheduled review,
and (since #2169) the UserPromptSubmit mechanism-failure notifier's
pre-workflow-init exemption (`hooks/user-prompt-submit-mechanism-check.js` —
see "Exception: pre-workflow-init sessions get no notification" below). A
naive "is any step settled?" check is fooled by cross-session
inheritance (`hooks/session-start.js` can replay a prior session's entire
event stream, stamped `origin: "session-inherit"`), so the predicate is an
explicit allow-list on the settling event's `origin`, not a denylist on
`session-inherit`: only origins known to represent the current session's own
genuine action count (CPR-UNV — no implicit fallback).

`hooks/workflow-state/lifecycle.js#isEffectivelyPendingStep` is the separate,
narrower SSOT for a different question — not "did this session start the
workflow" but "did this specific step receive any genuine work" — used by
adoption-gate readers deciding whether a heir session's step is safe to
overwrite. Its sole consumer today is
`hooks/workflow-state/inheritance/adopt.js#isAllPending` (#2279); any future
reader asking "is this step still untouched" should call it rather than
re-deriving the same in-progress/origin check.

`ADOPTION_ORIGINS` currently contains:

- `mark-step` — the direct, user/skill-driven completion path (default
  origin when `markStep()` is called without an override).
- `migration-v1-to-v2` — the legacy-schema upgrade path; it replays THIS
  session's own pre-#1733 history into the new event-stream schema, so it is
  not session inheritance.
- `reset-sentinel` — the `WORKFLOW_RESET_FROM_{step}` sentinel path
  (`hooks/workflow-mark/reset-handler.js`). This sentinel is gated by
  `permissions.ask` in `settings.json`, so every reset-sentinel event
  required the user's explicit, THIS-session approval — as genuine as a
  direct `mark-step` call, even though the rollback it produces resets later
  steps to `pending`.

Deliberately EXCLUDED: `session-inherit` (cross-session inheritance, by
design — see above); `next-step-evidence-resolution` /
`next-step-recorded-verdict-skip` (automated `next-step` auto-persist paths
— see `bin/workflow/lib/next-step/verdict.js` header comment); and any
automated PostToolUse detection such as `hooks/workflow-run-tests.js`'s
pattern-matched test-command completion, which carries its own explicit
`workflow-run-tests-auto-detect` origin override for exactly this reason — a
pattern-matched Bash command is not a deliberate workflow action, so it must
not silently satisfy adoption via the default `mark-step` origin.

The scan is existential and order-independent in one direction: once a
genuine adoption-worthy event has been appended anywhere in the stream, later
auto/backfilled noise (or even a `reset-sentinel` rollback) can never erase
that the session did, at some point, genuinely engage with the workflow —
see `tests/feature-1794-stop-guard-exemptions/i-adoption-predicate.sh` (I11)
for the locked-in truth table.

### Delegated-step in-flight allow-list (`STEP_IN_FLIGHT_ALLOWLIST`, #2013)

C4 fires when the session stops while `next-step` still says `ACTION=invoke`.
That is exactly what a *dispatch* looks like from the outside: the main
conversation hands the step to a subagent through the Agent / Task / Skill
tools and then waits. Before #2013 the step had to be declared in flight by
hand (`NEXT_STEP_PAUSE`), and a forgotten declaration nudged the session
mid-dispatch.

The declaration is now the dispatch itself. `hooks/postuse-step-in-flight-mark.js`
(PostToolUse, matcher `Agent|Task|Skill`) resolves the session's current
effective step and, if that step is on the allow-list, records it
`in_progress`. `hooks/lib/step-in-flight-policy.js` is the SSOT for both the
allow-list and the TTL:

- `STEP_IN_FLIGHT_ALLOWLIST` — `research`, `detail`, `write_tests`,
  `review_tests`: the steps whose SKILL.md procedure genuinely delegates to a
  subagent. A step that runs in the main conversation is deliberately absent,
  so an incidental dispatch there never silences the guard.
- `STEP_IN_FLIGHT_TTL_MS` — 4 hours, the same window `write_code` uses.

Boundary properties, and where each is enforced:

- **Lookahead.** The first dispatch of a session can land during
  `/workflow-init` WI-10, before any state file exists. The hook resolves an
  absent state (or `workflow_init` still pending) to `research`, so the WI-10
  window is covered — a bounded special case, not an "always research" rule.
  The lookahead promotion itself is narrower than the general allow-list: it
  fires only for `Agent`/`Task` dispatches (`LOOKAHEAD_DISPATCH_TOOLS`,
  `isLookaheadDispatchTool`), not `Skill` — WI-10's own dispatch is a
  subagent call, so widening the lookahead window to `Skill` would mark a
  step in-flight on every ordinary skill invocation, not just the genuine
  first-dispatch case (#2279 D-3). Separately, any `Skill` dispatch whose
  resolved name is on `META_OP_SKILLS` (`isMetaOpDispatch`) — currently just
  `resume-session` — is never marked in-flight for any step, lookahead or
  not: a meta-operation skill inspects workflow state rather than performing
  it, so treating its own dispatch as work would taint the very state it is
  trying to read. `tests/TL3-hook-skill-dispatch-payload.sh` owns verifying
  that the host's real `tool_input.skill` payload shape still matches what
  `skillNameOf` expects.
- **Subagents are excluded.** A dispatch made *from inside* a subagent carries
  `agent_id`; the hook no-ops, so a nested dispatch cannot re-mark the step.
- **Idempotent.** Re-marking an already `in_progress` step appends no event.
- **Not an adoption origin.** The auto-mark never enters `ADOPTION_ORIGINS`
  above: it is an automated PostToolUse detection, so it must not make an
  inherited-only session look like it started the workflow itself.
- **`write_code` stays its own predicate.** `isWriteCodeInFlight` is unchanged
  and `write_code` is outside the allow-list; `anyStepInFlight` spans both for
  consumers that mean "is any delegated unit of work running?".
- **Expiry is not silence.** Past the TTL the record stops being honoured AND
  becomes a reportable mechanism failure — see `hooks/lib/mechanism-failure.js`,
  the UserPromptSubmit check `hooks/user-prompt-submit-mechanism-check.js`, and
  the fail-fast block in C4 (#1979 / #1997). Each finding is reported once per
  session, recorded in the `<sid>.stall-reported` ledger.
- **Exception: pre-workflow-init sessions get no notification for the WI-10
  lookahead mark specifically (#2169).** The gate is evaluated **per finding**,
  not once per session: `hooks/user-prompt-submit-mechanism-check.js`'s
  `isFindingExemptFromPromptNotify(sid, finding)` exempts a finding only when
  BOTH `isWorkflowStarted(sid) === false` (checked against the `promptNotify`
  column of `EXEMPTION_MATRIX`, `hooks/lib/stop-exemption-policy.js`) AND
  `isLookaheadOnlyInFlight(sid, finding.step)` — the last `step_status` event
  recorded for that finding's own step came from the WI-10 lookahead mark
  specifically (`hooks/workflow-state/lifecycle.js`, origin
  `"postuse-in-flight"`), not from any other origin. A finding whose step's
  last mark has a different origin — a resumed/inherited session's genuinely
  stalled step, or the `(state)` pseudo-step used for corrupt/unreadable
  state — is NOT exempt and still notifies and writes the `.stall-reported`
  ledger normally, even though `isWorkflowStarted(sid)` is false for that same
  session. C4's fail-fast block is unaffected — only the UserPromptSubmit
  notifier is gated. A genuinely-started session whose allowlisted step
  overruns the TTL keeps being notified every prompt, unchanged (Accepted
  Tradeoff — intent.md).
- **C4's per-finding treatment (#2213) sits alongside this exception.** Both
  are grounded in the same `isLookaheadOnlyInFlight` check, but they gate
  different consumers: the bullet above scopes the UserPromptSubmit
  notifier's exemption per finding rather than per session; #2213 applies the
  same per-finding granularity to C4's own premature-stop evaluation, so a
  session with one genuinely-stalled step and one lookahead-only step is
  blocked for the former without being silenced for the latter.

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
