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
The WE-7 path (a PR already `MERGED` outside the session) ran neither `gh pr
merge` nor a protected-branch push, so its gate condition was never met and the
audit was skipped entirely — an asymmetry between the two merge-approval paths.

The fix moves the final decision point to just before `USER_VERIFIED`, which both
WE-7 and WE-8 always pass. Audits fire on **step-completion transitions**, and a
ledger records which step's audit judged which version of which artifact and when,
so the final point re-uses settled judgments instead of re-running them. No new
agent and no new state machine are introduced: the existing single-slot
supervisor-audit (arm → surface → clear) gains two triggers (TR4 write_code, TR5
user_verification), and the `gh pr merge` gate loses its arming duty and shrinks
to a read-only freshness backstop.

## Trigger table (SSOT: `hooks/lib/audit-triggers.js`)

Cause labels are unified in the module; no caller invents its own. The
`stage-boundary:` prefix is abolished — TR1–TR3 now use `step-complete:<step>`.

| ID | Step / condition | Cause | Kind | Input for `input_key` | Sub-checks |
|---|---|---|---|---|---|
| TR1 | `clarify_intent` complete | `step-complete:clarify_intent` | edge | intent.md | `intent-internal` |
| TR2 | `outline` complete | `step-complete:outline` | edge | intent.md + outline.md | `intent-outline` |
| TR3 | `detail` complete | `step-complete:detail` | edge | intent.md + outline.md + detail.md | `outline-detail`, `declared-files-snapshot` |
| TR4 | `write_code` complete | `step-complete:write_code` | edge | diff (`input_version`) | `detail-code`, `scope-drift`, `systemic-risk` |
| TR5 | `USER_VERIFIED` issue attempt | `step-complete:user_verification` | edge | diff (`input_version`) | `recurrence-patterns` (+ on re-audit, TR4's sub-checks) |
| TR6 | `cumulative_severity` = error | `severity-threshold:error` | level | diff (`input_version`) | all sub-checks |

TR1–TR5 are **edge** triggers: they fire once on the "incomplete → complete"
transition of their step, judged solely by whether the transition's identity is
already in the ledger — never by the diff fingerprint. Making the fingerprint an
arm condition would re-arm the same `write_code` audit on any later edit (a docs
step, say), breaking the "5 step completions only" rule. TR6 is the one **level**
trigger: its condition is a state, not a transition, so it is intentionally not
edge-ified; dedup falls to cause matching plus ledger staleness.

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
`declared_files.files` is capped at 500 paths; past that a `truncated` flag is set
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
  working tree, so they never appear in the diff.
- `computeFreshnessKey(cwd, plansDir, sessionId)` — combines `input_version` and
  the three `artifact_keys` into one composite key. Any null component makes the
  whole key null (fail-closed).

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
| BLOCK | match | **hold** (deny). Resolve only by (1) moving the input to get a non-BLOCK run on the new key, or (2) recording a rejection via `bin/supervisor-record-block-override`. |
| BLOCK | mismatch | arm a run against the new key (deny + dispatch). Non-BLOCK → stage 2; BLOCK again → hold again. |
| key uncomputable — code-side null (`input_version` null, e.g. no merge base / shallow clone) | — | **approve** when the last terminal run is non-BLOCK and no later BLOCK exists (`selfRecovering`); arm a full re-audit otherwise. `recurrence-patterns` is excluded from the arm set because its `input_key` is always null here (infinite-arm guard, #2323). |
| key uncomputable — artifact-side null (`input_version` non-null, plan artifact missing) | — | **approve** when `selfRecovering` AND `trigger_input_keys.TR5` of the last terminal run matches the current `input_version`; arm a full re-audit (excluding `recurrence-patterns`) otherwise. Fail-closed: absent, null, or non-string stored key arms a re-audit (#2360). |

**Stage 2 — diff-driven re-audit (including plan-artifact freshness).** Judged on
two axes: (α) does code-side `input_version` match the last terminal run, and (β)
do the intent / outline / detail artifact keys match the run that last judged each
plan sub-check (via `isSubCheckSettled`). Watching only (α) would let a post-TR3
detail.md edit pass on stale judgment; (β) closes that. Outcomes range from
"pass (recurrence patterns already settled and the last terminal run covered TR5)"
through "arm a recurrence-patterns-only TR5 run", "changed-file-scoped re-audit",
up to "full re-audit" when a change reaches outside the declared file set, when
review_security is skipped/failed, or when the ledger / identity / snapshot /
freshness key is missing or inconsistent.

**Termination** rests on `freshness_key`, not an attempt counter: once a verdict
is terminal and non-BLOCK for the current key with TR5 covered, the next attempt
passes. Untouched plan artifacts keep (β) all-matching, so the normal flow adds no
extra arms. `uv_attempt_seq` is recorded only for tracing.

### BLOCK rejection record

`bin/supervisor-record-block-override` takes session-id / run-id / reason
(minimum length enforced), appends `{ run_id, freshness_key, reason, actor,
timestamp }` to `audit.block_overrides`, and forces a `severity=warning,
category=audit-override` supervisor finding — there is no silent bypass
(fail-closed). Stage 1 treats a BLOCK as resolved only when an override matches on
**both** `run_id` and `freshness_key`, so any later code diff or intent / outline /
detail edit invalidates the override automatically.

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
Consolidating the arm source onto the Stop hook (TR1–TR6) structurally removes the
race where the gate and the Stop hook armed at the same time.

## State writer locking

Because TR4's background dispatch runs concurrently with run_tests /
review_security, `hooks/lib/supervisor-state-writer/lock.js` `withStateLock`
guards every read-modify-write entry point (read included, not just the write) in
`audit.js` / `alert.js` / `append.js`. The lock is an `fs.mkdirSync` directory
plus an owner-token file, re-entrant within one process, with a stale-reclaim path
after 10s. Lock-acquire failure is fail-closed (no write). The reclaim-after race
is deliberately not defended (see the outline Accepted Tradeoffs) — the owner-token
lock is enough for a single-user PC hook model.
