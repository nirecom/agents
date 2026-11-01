# Supervisor Audit Ledger, Run Identity, and Pre-merge Backstop

What and why for the #2256 shift-left of the EM Supervisor pre-merge audit.
The parent [claude-code.md](../claude-code.md) EM Supervisor section stays the SSOT
for the alert/audit two-mode design and the `alert` / `audit` state-file fields;
this file owns the ledger, the run identity, the trigger table, the freshness
key, the TR5 two-stage user-verification hold, and the pre-merge freshness
backstop. It does not restate what claude-code.md already covers.

## Why shift-left

The old design ran the pre-merge audit only when `gh pr merge` fired — that is,
**after** `USER_VERIFIED` was already issued. A WARN or BLOCK surfaced after the
user had approved, forcing a whole extra revise cycle (issue #2160 / PR #2253).
The web-merged path (a PR already `MERGED` outside the session) ran neither `gh pr
merge` nor a protected-branch push, so its gate condition was never met and the
audit was skipped entirely — an asymmetry between the two merge-approval paths.

The fix moves the final decision point to just before `USER_VERIFIED`, which both
paths always pass (since #2527 both are issued by `/get-release-approval`). Audits fire on **step-completion transitions** (the plan stages before their CONFIRM, see [Pre-confirm audit](#pre-confirm-audit-tr1tr3)), and a
ledger records which step's audit judged which version of which artifact and when,
so the final point re-uses settled judgments instead of re-running them. No new
agent and no new state machine are introduced: the existing single-slot
supervisor-audit (arm → surface → clear) gains two triggers (TR4 write_code, TR5
user_verification), and the `gh pr merge` gate loses its arming duty and shrinks
to a read-only freshness backstop.

## Trigger table (SSOT: `hooks/lib/audit-triggers.js`)

Cause labels are unified in the module; no caller invents its own. The
`stage-boundary:` prefix is abolished — TR1–TR3 use `pre-confirm:<step>` (#2853).

| ID | Step / condition | Cause | Kind | Input for `input_key` | Sub-checks |
|---|---|---|---|---|---|
| TR1 | `clarify_intent` confirm gate, before CONFIRM | `pre-confirm:clarify_intent` | pre-confirm | intent.md | `intent-internal` |
| TR2 | `outline` confirm gate, before CONFIRM | `pre-confirm:outline` | pre-confirm | intent.md + outline.md | `intent-outline` |
| TR3 | `detail` confirm gate, before CONFIRM | `pre-confirm:detail` | pre-confirm | intent.md + outline.md + detail.md | `outline-detail`, `declared-files-snapshot` |
| TR4 | `write_code` complete | `step-complete:write_code` | edge | diff (`input_version`) | `detail-code`, `scope-drift`, `systemic-risk` |
| TR5 | `USER_VERIFIED` issue attempt | `step-complete:user_verification` | edge | diff (`input_version`) | `recurrence-patterns` (+ on re-audit, TR4's sub-checks) |
| TR6 | `cumulative_severity` = error | `severity-threshold:error` | level | diff (`input_version`) | all sub-checks |

TR4–TR5 are **edge** triggers: they fire once on the "incomplete → complete"
transition of their step, judged solely by whether the transition's identity is
already in the ledger — never by the diff fingerprint. Making the fingerprint an
arm condition would re-arm the same `write_code` audit on any later edit (a docs
step, say), breaking the "5 step completions only" rule. TR6 is the one **level**
trigger: its condition is a state, not a transition, so it is intentionally not
edge-ified; dedup falls to cause matching plus ledger staleness. TR1–TR3 are
**pre-confirm** triggers: the Stop hook no longer arms them; the plan step's confirm
gate does (next section).

## Pre-confirm audit (TR1–TR3)

Why: an edge trigger on a gated plan step can fire only after its CONFIRM, so a
WARN or BLOCK arrived after the user approved, and fixing the plan broke the
approval hash and forced a re-approval. Arming before the CONFIRM changes only the
order; the approval hash is untouched. `hooks/lib/pre-confirm-audit.js` owns the judgment.

- **Arm point.** `next-step --gate` on a plan step (intent / outline / detail) judges
  the stage just before it would return `ask` or `proceed`, whether the stage's
  CONFIRM is on or off. An already approved stage is not audited again. A detail
  scope change still returns `present-and-stop` first.
- **Gate outcome.** `REASON` carries `pre-confirm-audit:<state>`; the extra output
  lines are `GATE_AUDIT_RUN_ID` and `GATE_AUDIT_VERDICT`.

| State | `GATE_ACTION` |
|---|---|
| `settled-continue`, `accepted` | the original `ask` / `proceed` |
| `settled-warn` | the original action; `GATE_HINT` carries the WARN summary and run id |
| `unsettled` | `audit-wait` — the gate arms a run and prints the launch hint |
| `settled-block`, `cap-reached`, `error` | `audit-block` — the hint gives the fix steps or the acceptance command |

- **CONFIRM refusal.** `hooks/confirm-checkpoint.js` denies a plan-stage CONFIRM
  echo, before spending the presentation receipt, unless the stage is
  `settled-continue`, `settled-warn` or `accepted`.
- **Stage verdict.** A stage is settled when every sub-check of its TR is settled
  at the current `input_key`. When those sub-checks settled in different runs, the
  stage verdict is the heaviest (BLOCK > WARN > CONTINUE) of each sub-check's
  latest terminal verdict.
- **Audit run count.** `audit.audit_run_counts` (`{ TR1, TR2, TR3 }`) rises by one
  only when the gate mints a new run; an idempotent re-arm or a moved
  `input_version` does not count. The cap is 2+1: at 3 the gate arms no more and
  returns `audit-block` (`cap-reached`). A successful `RESET_FROM` to a plan step
  resets that stage and every later stage to 0; a failed reset of the count keeps the
  reset and only warns.
- **Order.** Review finishes before the pre-confirm audit: CPA-3 runs `--gate`
  only after the review loop approves (outline / detail). A BLOCK fix goes through
  the planner revise and the review loop, then `--gate` again; intent has no
  review loop and re-runs `--gate` directly. Both loops are capped, so the round
  trip ends.
- **Acceptance.** The ask-gated `WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED` sentinel
  also accepts a TR1–TR3 run: a terminal WARN / BLOCK, or the current unsettled
  run (pending / in_progress / frozen) recorded as `UNSETTLED`, which also
  releases that run (outcome `discarded-stale`, `audit_phase` done). Before the
  cap, an acceptance counts only while its `trigger_key` equals the stage's current
  key. After the cap, the acceptance of the stage's last run counts whatever the
  key, because past the cap the user takes over the judgment: a plan edited after
  that acceptance passes the gate with no further audit. TR4 / TR5 runs are never
  accepted as `UNSETTLED`, and the TR5 release rules below are unchanged.
- **Fail-closed on an exception.** When judging or arming throws, the gate returns
  `audit-block` (`pre-confirm-audit:error`) and the checkpoint denies; neither falls
  back to the original action. The exit is the acceptance sentinel: when the
  stage's last run carries an acceptance (read without computing `input_key`), both
  pass. Two cases have no such exit — no run exists yet, or the supervisor state
  is unreadable — and the hint asks to re-run `--gate`.
- **Markers.** `WORKFLOW_OFF` (`/enforce-workflow-off`) is the user exit for the two
  cases above: with `.workflow-off` present, `next-step --gate` skips the audit
  judgment and returns the CONFIRM action (`pre-confirm-audit:skipped-workflow-off`),
  and `hooks/confirm-checkpoint.js` skips its audit check. Nothing else is lifted:
  the checkpoint's size and receipt checks never read the marker
  ([marker-bypass-contract.md](marker-bypass-contract.md)).
- **No workflow state.** The checkpoint skips the audit check for a session with no workflow state file, which cannot arm a run, and records a `notice` finding so the skip stays visible; a state file that exists but fails to read or judge stays fail-closed.
- **Verdict summary is data.** A settled WARN / BLOCK's summary comes from untrusted plan and transcript text, so `--gate` prints it on its own `GATE_AUDIT_SUMMARY` line (quotes stripped, whitespace collapsed, 400 characters at most) and never inside the verbatim-followed `GATE_HINT`.
- **Verdict writer.** Only a subagent may write a verdict: `hooks/block-main-audit-verdict.js` blocks the main conversation from calling `bin/supervisor-write-audit-verdict` or `--set-audit-verdict`, so the main conversation's only exit is the ask-gated acceptance sentinel.

### Declared-files snapshot (#2448)

TR3 records the declared files as two sets plus a scope tag:

- `plan_files` — files named in detail.md's `## Files to modify`, one path per line:
  only the first path token of a line counts, so a file merely referenced in the
  description is not collected. Scope drift is judged against this set. Write one
  file per line; a second file on the same line is dropped and later shows up as
  scope drift.
- `files` — the part of `plan_files` inside the working-tree diff (same path, or
  under a declared directory).
- `diff_scope` — `empty` (no diff yet, the normal case at the pre-confirm TR3),
  `unavailable` (the diff could not be computed), or `scoped`. A later arm with a
  non-empty diff recomputes `files` without re-parsing detail.md; `plan_files` and
  `detail_key` are recomputed only by an arm that includes TR3 or follows a narrowing.

A snapshot without `plan_files` (pre-#2448) is still read through `files`, then the
detail parse. The TR5 narrowing check compares `plan_files` (else `files`).

### Sub-check registry

The same module carries a sub-check registry — `sub_check_id` → input kind (plan
artifact vs diff) → `earliest_tr` (the earliest trigger that can judge that
concern). It is the SSOT for the rule "an un-settled concern is picked up by the
next arm". `recurrence-patterns` has `earliest_tr=TR5`; the three plan-artifact
sub-checks (`intent-internal` / `intent-outline` / `outline-detail`) belong to
TR1 / TR2 / TR3. A sub-check is settled per `<sub_check_id>@<input_key>`, so a
later trigger re-judges only the concerns whose input actually moved.

## Audit run identity

Every arm mints an identity — `run-<4-digit zero-padded seq>` (e.g. `run-0007`) —
from a monotonic `run_seq` on the session state file. No random component: test
reproducibility and log/finding readability win, and per-session monotonicity is
enough for uniqueness. Numbering happens inside the **same** read-modify-write as
the phase write, so the mint and the phase write cannot split and strand an
identity.

The identity binds four things into one unit: `audit_phase` (pending /
in_progress), the background-dispatch argument, verdict finalization, and the
ledger entry. A verdict is finalized only when the identity being finalized is the
one currently in-flight (a compare-and-set); a verdict for a superseded run is
discarded (exit 3) and recorded as `discarded-stale`, never clobbering the
current run. This removes two race classes mechanically: a pending phase erased
by an unrelated later write, and an old verdict finalizing a freshly-armed run.

## Unshown runs and the launch-directive suppression window

`audit_dispatched_at` records when the launch instruction for the pending run was
shown. A run that is pending, has an identity, and has no `audit_dispatched_at` is
an **unshown run** (`unshownRun()` in `hooks/lib/audit-ledger.js` is the single
predicate). An unshown run never blocks a later arm: an arm that shows its launch
replaces it, and the replaced entry is closed with the `superseded` outcome.

The launch-directive suppression window (`inPostAlertSuppression`) starts when an alert review
completes. A Stop with at most one human prompt since then (`countHumanPromptsSince`) is inside it; when
the count cannot be determined, the Stop is treated as outside. Inside it the
system only arms the audit run and shows no standalone launch instruction. The
pending launch is released at one of three points: bundled into the next alert
block, the first Stop outside the suppression window, or the TR5 gate.

Why: right after an alert finding, a second launch request would read to the user
as consecutive, back-to-back interruptions. Result display keeps its existing two
paths; only the timing of the launch instruction changes.

## Ledger entry and query API

The ledger is an append-only array in the `audit` block of the supervisor state
file. Each entry carries the identity (`id`), the coalesced `tr_ids` and `cause`,
the consumed `transitions`, the code-side `input_version`, its `input_base`, the
canonical per-sub-check `input_key` (`{ <sub_check_id>: <key> }` — the only
canonical shape, whether or not triggers coalesced), the auxiliary
`trigger_input_keys` (per-TR record, never used for dedup or freshness), the three
`artifact_keys` (`{ intent, outline, detail }`), the composite `freshness_key`,
`declared_files_narrowed`, the judged `sub_checks`, the TR4 `scope_drift` result,
the `verdict` / `verdict_summary`, an `outcome` (armed / terminal /
discarded-stale / superseded), and `armed_at` / `terminal_at`.

Four pure queries are exposed by `hooks/lib/audit-ledger.js`:
`lastTerminalRun(audit)` (optionally filtered by TR-ID), `isTransitionConsumed`,
`isSubCheckSettled(audit, subCheckId, inputKey)` (is `<sub_check_id>@<input_key>`
in a terminal run's sub-checks × input_key), and `isRunFresh(entry,
freshnessKey)` (does the entry's `freshness_key` equal the current composite key —
either being null is false, fail-closed).

### Retention

`ledger` is a 40-entry FIFO, `consumed_transitions` a 200-entry FIFO,
`block_overrides` a 20-entry FIFO. The entry whose `id` equals
`last_terminal_run_id` is never dropped (the backstop and TR5 stage 1 read it).
`declared_files.files` and `declared_files.plan_files` are each capped at 500 paths; past that a `truncated` flag is set
and TR5 falls to full re-audit.

## Judgment input version and the freshness key

`hooks/lib/branch-diff.js` `computeWorkingTreeDiff(cwd)` is the single source of
the working-tree diff (committed + staged + unstaged + untracked), returning the
merge base, the raw `git diff --raw` records, the changed-file set, and the
human-readable diff text (for the agent prompt only). It is the sole input for
both TR4's scope-drift check and `computeInputVersion`, memoized once per hook run.

`hooks/lib/diff-fingerprint.js` computes three keys, all full-streaming **sha256**
with the **entire 64-hex digest** kept — never truncated, because a truncated
identity key is a collision attack that reuses an audited verdict for different
input:

- `computeInputVersion(cwd)` — hashes the **changed file contents and git object
  identity** (merge base, raw records, then each path's bytes / symlink target /
  gitlink sha), not the rendered diff text. Diff text is rejected as input because
  `git` renders binaries (and `-diff` / textconv / external-diff text files) as a
  content-independent `Binary files … differ` line, which would let their contents
  change without moving the version and pass a stale audit. No size truncation —
  truncating reopens the same hole for "same first N bytes" binaries. Null when
  git is unavailable, treated by callers as unknown = fail-closed.
- `computeArtifactKey(plansDir, sessionId, names)` — hashes the named plan
  artifacts' full bytes. Plan artifacts live under `PLANS_DIR`, outside the repo
  working tree, so they never appear in the diff. Null when an artifact is absent
  (nothing at the path) or unreadable (any other stat or read failure, not a
  regular file, or a dangling symlink).
- `computeFreshnessKey(cwd, plansDir, sessionId)` — combines `input_version` and
  the three `artifact_keys` into one composite key. Any null component makes the
  whole key null (fail-closed). It tells the two apart: an absent artifact is a
  null value inside `artifact_keys` (compared as a value), while an unreadable one
  collapses `artifact_keys` itself to null and is listed in
  `unreadable_artifacts`. A run armed in that state records no breakdown, so it
  can never certify a null key later.

The composite key is what makes plan-artifact edits visible. `input_version` alone
never moves when detail.md is edited after TR3 — the artifact is outside the diff
and the detail transition key is already consumed — so a narrowing of the declared
file set could slip a stale audit and stale snapshot past `USER_VERIFIED`. The
composite key forces any intent/outline/detail edit to register as a freshness
mismatch.

## TR5 — the user-verification hold

TR5 arms once per `USER_VERIFIED` issue attempt and runs two stages before the
sentinel is allowed.

**Stage 1 — unresolved-BLOCK hold.** Reads the last terminal run:

| Last terminal verdict | `freshness_key` | Action |
|---|---|---|
| BLOCK | match | **hold** (deny). Resolve only by (1) moving the input to get a non-BLOCK run on the new key, or (2) recording a reviewed acceptance via the ask-gated `WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED` sentinel (see below). An acceptance releases only while no newer audit run is unsettled; otherwise a fresh run is armed. |
| BLOCK | mismatch | arm a run against the new key (deny + dispatch). Non-BLOCK → stage 2; BLOCK again → hold again. |
| key uncomputable — code-side null (`input_version` null, e.g. no merge base / shallow clone) | — | **approve** when the shared null-freshness predicate (`hooks/lib/null-freshness.js`) certifies the last TR5 terminal run: verdict CONTINUE (a WARN / BLOCK with a matching reviewed acceptance is refused on a code-side null: `inputs-moved` when the run stored a diff key, `no-trigger-key` when it stored none — the acceptance releases only the artifact-side null below) — no later BLOCK, no newer audit run unsettled (`audit_phase` pending / in_progress / frozen), and every per-artifact hash (`artifact_keys`, absence compared as a value) unchanged since that run; arm a full re-audit otherwise. A run without a per-artifact breakdown is fail-closed. `recurrence-patterns` is excluded from the arm set (infinite-arm guard, #2323). |
| key uncomputable — artifact-side null (`input_version` non-null, plan artifact missing) | — | Same predicate, plus `trigger_input_keys.TR5` of that run must equal the current `input_version` (absent / null / non-string stored key is fail-closed, #2360). Hashing the artifacts closes the hole where a post-TR5 intent/detail edit passed on a code-only match (#2400). |

An unreadable plan artifact holds the sentinel without arming, on either null
kind — no audit can judge it. A code-side null key with every plan artifact
absent has nothing left to compare, so no acceptance can certify it (fail-closed).

**Stage 2 — diff-driven re-audit (including plan-artifact freshness).** Judged on
two axes: (α) does code-side `input_version` match the last terminal run, and (β)
do the intent / outline / detail artifact keys match the run that last judged each
plan sub-check (via `isSubCheckSettled`). Watching only (α) would let a post-TR3
detail.md edit pass on stale judgment; (β) closes that. Outcomes range from
"pass (recurrence patterns already settled and the last terminal run covered TR5)"
through "arm a recurrence-patterns-only TR5 run", "changed-file-scoped re-audit",
up to "full re-audit" when a change reaches outside the declared file set, when
review_security is skipped/failed, or when the ledger / identity / snapshot /
freshness key is missing or inconsistent. While a newer audit run is still
pending / in_progress / frozen, stage 2 never passes on the older verdict: it arms
a fresh run that supersedes the in-flight one (#2534).

**Termination** rests on `freshness_key`, not an attempt counter: once a verdict
is terminal and non-BLOCK for the current key with TR5 covered, the next attempt
passes. Untouched plan artifacts keep (β) all-matching, so the normal flow adds no
extra arms. `uv_attempt_seq` is recorded only for tracing.

### Reviewed verdict acceptance

Why: a WARN or BLOCK the user has reviewed must not hold `USER_VERIFIED` forever,
and on a null key a WARN used to re-arm the audit on every emission (#2597).

The only write path is the sentinel
`echo "<<WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED: <run-id> <reason>>>"`. A
`permissions.ask` rule in `settings.json` puts every emission through the user's
approval dialog (ask outranks allow), so the model cannot record an acceptance on
its own (#2709). The workflow-mark handler
(`hooks/workflow-mark/supervisor-block-override-handler.js`) delegates to
`hooks/lib/supervisor-block-override.js`, which refuses a reason under 20
characters before touching state, and a run id that is not the last terminal run
or whose verdict is not WARN or BLOCK (except the TR1–TR3 `UNSETTLED` case of
[Pre-confirm audit](#pre-confirm-audit-tr1tr3)). It writes to the same supervisor state the
TR5 gate reads (`resolveSupervisorState().effectiveSid`), appends `{ run_id,
verdict, freshness_key, artifact_keys, trigger_key, reason, actor, recorded_at }`
to `audit.block_overrides`, and forces a `severity=warning` supervisor finding
(reporter `workflow-mark:supervisor-block-override`) — there is no silent bypass.
A malformed emission draws a format error and records nothing. The retired name
`WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED` records nothing and points at the new name:
its ask row is gone, so honouring it would let an un-dialogued emission write.

`hooks/lib/null-freshness/acceptance.js` decides when a record releases, always
matched against the TR5 run's own `id` and `verdict`:

- Non-null key: the record's `freshness_key` must equal the current key.
- Null key: the record must pin the run's snapshot — `freshness_key`, every
  `artifact_keys` entry, and the TR5 `trigger_key` — and the shared predicate
  must still pass, so any later code diff or intent / outline / detail edit
  invalidates the acceptance automatically.
- A record written before #2597 (no `verdict`) is read as a BLOCK acceptance and
  releases only on the non-null path.
- A record never outranks a later BLOCK or a newer unsettled run; anything
  malformed is ignored (fail-closed).

## Pre-merge freshness backstop

`hooks/workflow-gate/supervisor-check.js` `checkSupervisorPreMerge` loses its
arming duty. It no longer arms any audit state; it only verifies that a terminal
run covering TR5 exists in the ledger, that its `freshness_key` equals the current
composite key, and that its verdict is not an unresolved BLOCK. Otherwise it
denies with cause `freshness-backstop:pre-merge` (the sole remaining backstop
cause; `pre-merge-warning-flush` and `scope-drift:pre-merge` are removed) and
names which component moved (code diff / intent / outline / detail). No agent is
launched. The former Path (i-b) BLOCK check stays as a double-check for the
abnormal case where TR5 did not fire, recording a finding when reached.
Consolidating the arm source onto the Stop hook (TR4–TR6) and the plan confirm gate (TR1–TR3) structurally removes the
race where the gate and the Stop hook armed at the same time.

When the composite key is null, the backstop applies the same null-freshness
predicate as the TR5 hold after checking that a TR5 run exists and no later BLOCK
postdates it; it approves only when the predicate certifies the run and otherwise
denies naming the null kind and what moved. It also denies while a newer audit
run has no verdict (armed, in progress, or frozen): with a code-side null key,
code moved after TR5 is invisible, and a pending later run could still return
BLOCK. An unreadable plan artifact is denied by name rather than compared as
absent. A WARN or BLOCK passes a null key only with a reviewed acceptance that
pins the run's snapshot (see [Reviewed verdict acceptance](#reviewed-verdict-acceptance)).
On a non-null key the backstop likewise denies while a newer run is unsettled,
even when the fresh verdict is accepted (#2534). Sharing one predicate keeps the
sentinel gate and the merge gate from disagreeing (#2400).

## State writer locking

Because TR4's background dispatch runs concurrently with run_tests /
review_security, `hooks/lib/supervisor-state-writer/lock.js` `withStateLock`
guards every read-modify-write entry point (read included, not just the write) in
`audit.js` / `alert.js` / `append.js`. The lock is an `fs.mkdirSync` directory
plus an owner-token file, re-entrant within one process, with a stale-reclaim path
after 10s. Lock-acquire failure is fail-closed (no write). The reclaim-after race
is deliberately not defended (see the outline Accepted Tradeoffs) — the owner-token
lock is enough for a single-user PC hook model.
