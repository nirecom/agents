# Jev Two-Stage Broker

The protocol behind `bin/workflow/jev-judge`: how one judgment is asked,
completed, recorded and settled. The overview, the registry and the security
properties are in [../jev.md](../jev.md); the caller's steps are in
`skills/_shared/jev-two-stage-judge.md`.

## Why two stages

Jev answers most keys of a judgment with high confidence, but not all of them,
and a subagent can only be dispatched by the main conversation — never by a CLI.
So one judgment is split around that dispatch:

1. `query` asks Jev and decides which keys it may answer alone.
2. The caller dispatches the backup subagent for the remaining keys, only when
   there are any.
3. `finalize` merges both sides, records the decision and settles the result.

A judgment Jev answers completely costs no subagent call at all. A judgment it
cannot answer costs exactly what it cost before Jev existed.

## Ticket

`query` creates one ticket per judgment: a 16-hex id, a `cli-ticket` hand-off
file in the session's Jev state, and the files named below. Everything
`finalize` needs is in the ticket, so `finalize` takes only the session and the
ticket id — never a path or an answer on its command line.

| File | Where | Purpose |
|---|---|---|
| Snapshot `<session>-jev-<ticket>-snapshot.md` | plans directory | The exact bytes sent to Jev; the subagent reads it first |
| Answer `<session>-jev-<ticket>-answer.txt` | plans directory | The subagent's answer, written by the caller; the only channel into `finalize` |
| Source copies `jev-sources/<ticket>/` | session control directory | Whole copies of the stage's source artifacts, each with its sha256 |
| Done marker `tickets-done/<ticket>.json` | session Jev state | The stdout of a finished `finalize`, re-printed on a re-run |

### Policy freeze

`query` copies the point's policy into the ticket: `mode`, the recording owner,
whether a decision is recorded, both per-direction thresholds, the
short-circuit answer, the backup subagent and the fallback. `finalize`, the
replay and the orphan sweep read the ticket, never the registry.

The reason is consistency: if the registry changed between `query` and
`finalize`, the gate would have been applied under one policy and the record
written under another — for example a production ticket whose Jev answers were
adopted would be logged as shadow. A registry change therefore takes effect
from the next ticket queried. A ticket already queried finishes under the
policy it started with, or becomes an orphan after its one-hour lifetime.

`JEV` is frozen the same way: a ticket queried with `JEV=on` writes its
decision record even if the flag is off by `finalize`, and the reverse writes
none.

## Query

### Snapshot and required sections

Each stage has a fixed list of source sections (`STAGE_SOURCE_SECTIONS` in
`bin/workflow/lib/jev-request-common.js`): the intent, the outline, the detail
plan, the write-code file list and the issue body, as the stage has them.
`query` copies each source whole, then packs the redacted sections into one
snapshot within the 16 000-character budget — required sections first, a header
stating which sections are full, truncated or absent.

The registry names, per stage, the sections that must be whole
(`required_sections_by_stage`). Every stage requires the intent and the issue
body: a judge never decides without the request it is judging. A required
section counts as missing when it is truncated or absent in the snapshot, or
when its whole copy could not be made. Two named exemptions exist, and no
others: `producer-step-skipped` (the outline or detail plan was skipped, so
there is nothing to require) and `no-issue` (the session has no issue).

When a required section is missing, Jev is not asked: every key is delegated
and the record carries `fallback_reason: "input-insufficient"`. The subagent
can still read the whole copies, so it decides with more than Jev would have
seen. A long issue combined with a long plan is the usual cause; that is the
designed cost of requiring the issue body.

A copy fails for one of two recorded reasons: `copy-failed` (the write or its
sha256 check failed) or `over-cap` (the source exceeds the 1 MiB read cap).

### Deterministic signals

At the `write-code` stage, `S1b-wide-change` and `S4-installer` are computed
from the write-code file list rather than judged
(`hooks/workflow-state/complexity-routing/deterministic-signals.js`). Neither
Jev nor the subagent is asked about them, and a subagent answer naming one is
overridden by the computed value. The computation reads the ticket's copy of
the list, so the record's `deterministic.source_sha256` identifies the bytes
it used. A list that is missing, invalid or not copied fails safe to
`S0-undecidable`.

### Gate

Each Jev answer is a probability `p` that the key's yes side holds. Its
direction is yes when `p >= 0.5`, its confidence is `max(p, 1 - p)`, and it is
adopted when that confidence reaches the threshold for its direction
(`confidence_threshold_by_answer`). The thresholds are per direction because
the two mistakes do not cost the same: wrongly running a planning stage costs
time, wrongly skipping one loses a review.

A point may name a short-circuit answer. Once Jev's adopted answer for any key
equals it, the point is decided: for a skip point, one criterion adopted as
"does not hold" means the stage runs, whatever the other criteria say. The
keys Jev did not answer confidently are then left unjudged — recorded in
`unjudged_keys` and filled with the run-side value — instead of costing a
subagent call that could not change the outcome.

`query` prints `RESULT=final` when no key is delegated, else
`RESULT=need-subagent` with the subagent to dispatch and the delegated keys.

## Finalize

`finalize` claims the ticket, reads the answer file (1 MiB cap), and merges:
deterministic values, then Jev-adopted keys, then the subagent's answers for
the delegated keys. A skip key nobody answered becomes false — run the stage.
The raw subagent text is never stored.

### Write-ahead and replay

The merged result is written into the claim before any side effect. Every step
after that is idempotent and runs in a fixed order:

1. Append the decision record, once per (`ticket`, `record_type`).
2. Settle the result through the owner marker (below).
3. Write the done marker.
4. Drop the claim and the source copies.

A `finalize` stopped anywhere in that sequence is finished by re-running it:
the re-run finds the written-ahead result and replays the remaining steps, so
the outcome is the one an uninterrupted run would have produced. A ticket with
a done marker only re-prints its stdout. A claim left by a dead process is
taken over after ten minutes.

### Owner markers

Two judgments of the same stage can overlap — a restarted step, or two callers.
Which one is authoritative is decided by a marker file, never by comparing
contents: the judgment queried later wins.

- **complexity**: `<stage>-signals-owner.json` guards the fixed
  `<stage>-signals.txt`. `finalize` writes the file only as the newest owner.
  A write with no marker after this ticket's query also supersedes it.
- **skip**: `<target>-skip-owner.json` is taken at query time. Only the owner
  records the skip judgment, and only while the step is still pending.

A superseded ticket prints `SETTLE=superseded` and appends a second record of
type `settle` with the reason (`newer-owner`, `unowned-write` or
`step-not-pending`); its decision record is left untouched, because the log is
append-only and the settle outcome is not known when the decision is appended.
A superseded skip prints `SKIP=false`. A superseded complexity caller writes
nothing and stops: the newer judgment's caller continues the step.

Because the fixed file belongs to whichever judgment owns the marker, a caller
passes the `SIGNALS_CSV` printed by its own `finalize` downstream, never the
fixed file's content.

## Failure paths

- **`RESULT=error`** (exit 4): `finalize` could not complete — an unknown or
  unreadable ticket, an incomplete frozen policy, a failed log append. The
  caller re-runs once, then applies the fail-safe.
- **`jev-judge failsafe`**: settles the point's fallback through the same owner
  marker, as an owner dated at the caller's ticket's query time — it beats that
  ticket and loses to any newer query. The fallback is `S0-undecidable` (the
  highest routing level) for complexity and "run the stage" for a skip.
- **Missing answer**: a delegated ticket whose answer file is absent is
  finalized with those keys on the safe side and
  `fallback_reason: "answer-file-absent"`.
- **Orphans**: a ticket nobody finalized within an hour is handled by the
  sweep. One with a written-ahead result is replayed exactly as `finalize`
  would. One without is recorded once as `finalize-absent` and never settled —
  the caller has long since applied its own fail-safe.

## Shadow on the CLI path

A point in shadow mode still goes through `query` and `finalize`, with every
key delegated. Who records depends on whether the hook pair can observe the
dispatch: a point with a `subagent_type` of its own is recorded by the hooks
and the CLI asks Jev nothing; any other point is recorded by the CLI, which
asks Jev for the record only.
