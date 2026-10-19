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
| Jev input `<session>-jev-<ticket>-input.md` | plans directory | The exact bytes sent to Jev; the subagent reads it first |
| Answer `<session>-jev-<ticket>-answer.txt` | plans directory | The subagent's answer, written by the caller; the only channel into `finalize` |
| Source copies `jev-sources/<ticket>/` | session control directory | Whole copies of the stage's source artifacts, each with its sha256 |
| Done marker `tickets-done/<ticket>.json` | session Jev state | The stdout of a finished `finalize`, re-printed on a re-run |

### Policy freeze

`query` copies the point's policy into the ticket: `mode`, the recording owner,
whether a decision is recorded, both per-direction thresholds, the
short-circuit answer, the backup subagent, the fallback and the adapter.
`finalize`, the replay and the orphan sweep read the ticket, never the registry.

The registry is still consulted for one thing: whether the ticket may be used
at all. A ticket whose point or stage is no longer registered, or whose point
now names a different adapter, is refused (`ticket-invalid`) — another adapter
would read the frozen answers under different rules.

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

### Jev input and required sections

Each stage has a fixed list of source sections (`STAGE_SOURCE_SECTIONS` in
`bin/workflow/lib/jev-request-common.js`): the intent, the outline, the detail
plan, the write-code file list and the issue body, as the stage has them.
`query` copies each source whole, then packs the redacted sections into one
Jev input within the `MAX_JEV_INPUT_CHARS` budget — required sections first, a
header stating which sections are full, truncated or absent.

The budget is 30 000 characters (`hooks/lib/jev/two-stage/jev-input.js`). Jev's
state holds at most 32 000 tokens; at a safe-side 1.0 token per character that
is about 32 000 characters, less a margin of about 6 %. Measured Jev inputs run
at 0.69 tokens per character (p50), 0.81 at most; a CJK-heavy plan is estimated
at 0.92. A full input costs about $0.0009 to send. The budget is separate from
the shadow adapter's `MAX_STATE_CHARS` (16 000), which stays unchanged.

The `write-tests` and `write-code` stages require only the issue body, and name
their plan sections in priority order instead (`plan_sections_by_stage`: detail,
outline, intent). After the required sections and the write-code file list, the
detail plan goes in whole when it fits, then the outline and the intent in the
room left. When it does not fit, the outline is reserved first (whole when it
takes at most half the room, else cut to half), the detail plan fills the rest
with its Steps blocks (English or Japanese heading) moved to the end so the cut falls
there, and the intent takes whatever remains. The input is sufficient when at
least one plan section is full or truncated.

The Jev input is what Jev is sent, so it names the copies by file name only.
`query` prints their directory separately (`SOURCES_DIR`), and the caller hands
it to the subagent.

A source read at the 1 MiB cap is never stated as full. Its issue body runs to
the end of what was read: the heading that normally closes the section may lie
beyond the cut, so a line that looks like it inside the prefix is treated as
the issue's own text.

`query` also fingerprints every source artifact (sha256 of the whole file).
The settle step re-checks that fingerprint — see
[Source freshness](#source-freshness).

The registry names, per stage, the sections that must be whole
(`required_sections_by_stage`). Every stage requires the issue body, and every
stage without plan sections also the intent: a judge never decides without the
request it is judging. A required section counts as missing when it is
truncated or absent in the Jev input, or when its whole copy could not be made;
the plan sections all count as missing when none of them got in. Two named exemptions exist, and no
others: `producer-step-skipped` (the outline or detail plan was skipped, so
there is nothing to require) and `no-issue` (the session has no issue).

When a required section is missing, Jev is not asked: every key is delegated
and the record carries `fallback_reason: "input-insufficient"`. The subagent
can still read the whole copies, so it decides with more than Jev would have
seen. It happens when the required sections do not fit the budget — a long
issue body, or at the earlier stages a long intent or outline.

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
time, wrongly skipping one loses a review. A direction's threshold may be
`null`: Jev answers in that direction are never adopted and always go to the
subagent. `complexity-judge` uses this on the "does not fire" side, so every
such key collects a labeled record (Jev `p` plus the subagent's answer) before a
threshold for that side is set.

A point may name a short-circuit answer. Once Jev's adopted answer for any key
equals it, the point is decided: for a skip point, one criterion adopted as
"does not hold" means the stage runs, whatever the other criteria say. The
keys Jev did not answer confidently are then left unjudged — recorded in
`unjudged_keys` and filled with the run-side value — instead of costing a
subagent call that could not change the outcome.

A point may also hand the gate a decisiveness hook, so that an adopted
short-circuit answer decides the point only when the hook confirms it. The
complexity adapter's hook returns true only when the adopted signals route
every stage the judgment feeds to high; the gate itself never reads the
routing table. The hook reads the adopted keys as signals that hold, so it is
handed over only when the short-circuit answer is true; with any other answer
the short circuit stays value-based. A complexity short circuit leaves the unjudged signals out of
the fired set, and the record lists them apart in `final.unjudged_signals`, so
an unjudged signal is never read as absent.

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

Both markers are taken at the very start of `query`, before the sources are
read and before Jev is asked. An older judgment still in flight therefore
cannot settle during the newer query, however long that query takes.

- **complexity**: `<stage>-signals-owner.json` guards the fixed
  `<stage>-signals.txt`. The marker records the file's sha256 at query time,
  and `finalize` writes the file only as the newest owner.
  A write with no marker after this ticket's query also supersedes it, and so
  does one that lands after this ticket's own interrupted write: a replay keeps
  the newer value instead of writing over it.
  The write is a compare-and-write, because such a writer takes no lock: the
  file is renamed aside, the bytes set aside must be the ones the decision
  read, and the new file is created exclusively. A write that lands on either
  side of the rename is kept, never written over.
- **skip**: `<target>-skip-owner.json`. Only the owner
  records the skip judgment, and only while the step is still pending.
  `record-skip-judgment` accepts a judgment only for a ticket `finalize` has
  written ahead for the same session and target, with exactly that answer; a
  ticket id and conditions on a command line are not evidence of a judgment.
  A later query or fail-safe revokes a standing judgment, so every door that
  acts on one — `next-step`'s recorded-verdict skip, a `*_NOT_NEEDED`
  sentinel whose reason starts with `recorded-verdict:`, and
  `next-step --advance` with such a reason — re-reads it and writes the skip
  under the same owner lock. The advance door refuses that reason when no
  judgment stands, and fails closed when it cannot take the lock.
  `finalize` holds the lock while it runs `record-skip-judgment --advance`, so
  that child advances under its parent's hold instead of taking the lock again.

A superseded ticket prints `SETTLE=superseded` and appends a second record of
type `settle` with the reason (`newer-owner`, `unowned-write`,
`step-not-pending` or `source-changed`); its decision record is left untouched, because the log is
append-only and the settle outcome is not known when the decision is appended.
A superseded skip prints `SKIP=false`. A superseded complexity caller writes
nothing and stops: the newer judgment's caller continues the step.

Because the fixed file belongs to whichever judgment owns the marker, a caller
passes the `SIGNALS_CSV` printed by its own `finalize` downstream, never the
fixed file's content.

### Source freshness

A judgment describes the sources as they were at query time. If a plan is
edited between `query` and the settle, the judgment is about a plan that no
longer exists, so the settle re-hashes the stage's sources and compares them
with the ticket's fingerprint. A source that changed, appeared, vanished or
cannot be hashed whole all count as changed, and so does a ticket with no
fingerprint.

- **skip**: a judgment that would skip the stage is not recorded. The ticket
  prints `SETTLE=superseded` and `SKIP=false`, with the settle reason
  `source-changed`, and the stage runs. A judgment that already runs the stage
  is recorded as it is.
- **complexity**: the fail-safe level `S0-undecidable` is settled instead of
  the merged result, and printed as `SIGNALS_CSV`. A `settle` record with the
  reason `source-changed` is appended even though the settle itself succeeded.

Either demotion prints `FALLBACK=source-changed` (see
[Failure paths](#failure-paths)). The outcome is decided once per ticket, so a
re-run of `finalize` prints what the first run settled.

## Failure paths

- **`RESULT=error`** (exit 4): `finalize` could not complete — an unknown or
  unreadable ticket, an incomplete frozen policy, a failed log append. The
  caller re-runs once, then applies the fail-safe.
- **`jev-judge failsafe`**: settles the point's fallback through the same owner
  marker, as an owner dated at the caller's ticket's query time — it beats that
  ticket and loses to any newer query. The fallback is `S0-undecidable` (the
  highest routing level) for complexity and "run the stage" for a skip.
- **Missing answer**: a delegated ticket whose answer cannot be used is
  finalized with those keys on the safe side, and the reason becomes the
  record's `fallback_reason` (this list is the vocabulary's SSOT):
  - `answer-file-absent`: no answer file at `finalize`.
  - `answer-empty`: the file is empty or `NO_ANSWER`.
  - `answer-unparseable`: the file cannot be parsed — malformed, over the
    1 MiB cap, or a skip answer that leaves a key unanswered.

  When the output was demoted this way (or, for complexity, by a failed
  write-code list), `finalize` prints `FALLBACK=<reason>` after `SETTLE=`, and
  the caller shows it to the user. A skip ticket whose input was insufficient
  prints `input-insufficient` instead: the missing input is the root cause. A
  subagent's own `SIGNALS: S0-undecidable` is its answer, not a demotion.
  - `source-changed`: a source changed before the settle
    ([Source freshness](#source-freshness)). The settle decides it, so it goes
    into the settle record's `detail`, not the decision record's
    `fallback_reason`.

  At most one `FALLBACK=` line is printed, and a merge-time reason wins over
  `source-changed`. That order is defensive: for complexity the two never meet
  (a merge-time reason already settles `S0-undecidable`, so a source change
  demotes nothing), and for a skip they meet only when the subagent answers
  some keys but not all (`answer-unparseable`) and every condition still holds.
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
