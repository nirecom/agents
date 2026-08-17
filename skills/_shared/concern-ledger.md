# Concern Ledger — Shared Schema (SSOT)

One numbering for every concern a review produces, stable across rounds and across producers, so the author is told "this is the thing you already saw" instead of being handed a fresh list every round.

Implementation: `bin/lib/concern-ledger.sh`, reached through `bin/concern-ledger`. Design rationale: `docs/architecture/concern-ledger.md`. Never re-implement any rule below in a caller.

## Files

All paths derive from (`<PLANS_DIR>`, `<session-id>`, `<format>`) — no caller passes one in.

| File | Purpose |
|---|---|
| `<session-id>-<format>-concern-ledger.txt` | The ledger itself |
| `<session-id>-<format>-round-number.txt` | Round counter, one decimal integer |
| `<session-id>-<format>-round-<N>-delta-<producer>.txt` | One producer's staged round output |
| `<session-id>-<format>-concern-ledger-cap-snapshot.txt` | Ledger as it stood when the cap was reached |
| `<session-id>-<format>-unresolved-concerns.json` | Finalize artifact, schema `unresolved-concerns/v1` |
| `<session-id>-<format>-finalize-diagnostic.txt` | Why a finalize failed |

Formats in use: `outline-plan`, `detail-plan`, `security-plan`, `test-review`, `review-security-shared`.

## Ledger file

Line 1 is the header: `#concern-ledger-v2|<format>|<session-id>|cycle=<K>`.

Every other `C<N>|` line is one concern, eleven pipe-delimited fields:

| # | Field | Meaning |
|---|---|---|
| 1 | ID | `C<N>`, unique within the cycle, never reused |
| 2 | SEVERITY | `HIGH` / `MEDIUM` / `LOW` |
| 3 | STATE | `open` / `reopened` / `resolved` |
| 4 | FIRST_ROUND | Round the concern was first seen |
| 5 | LAST_ROUND | Round it was last touched |
| 6 | SLOT | The review address — 8 hex over path + anchor + category |
| 7 | DISCRIM | 8 hex over the case-folded, token-sorted text, frozen at first sight |
| 8 | ORIGIN | Producer that first reported it |
| 9 | PRODUCERS | Comma-separated producers that have reported it |
| 10 | FLAGS | Comma-separated, `-` when none |
| 11 | TEXT | The concern verbatim — the only field that may contain `\|` |

Two auxiliary line kinds carry what is not a concern: `#unparsed|<raw line>` (reviewer output no parser could read) and `#merged-alt|<id>|<body>` (another producer's wording folded into an existing concern). Both are content the author has never seen — surface them, never drop them.

A round 1 that meets a live ledger opens a new cycle rather than colliding with its IDs.

## Lifecycle

| STATE | Set when |
|---|---|
| `open` | Reported in the current round, or carried unresolved from an earlier one |
| `reopened` | A `resolved` concern was reported again |
| `resolved` | Absent from a round every declared producer completed |

Resolution is by absence, and absence only counts when the round was complete — see the fail-closed rule below.

## Vocabulary

Severity is `HIGH`, `MEDIUM`, or `LOW`; anything else is rendered but bucketed as OTHER.

Category is one of: `correctness`, `security`, `contract`, `performance`, `style`, `docs`, `test`, `maintainability`, `portability`, `concurrency`, `usability`, `other`. Anything outside the list is normalised to `other`.

## Producer contract

A producer is a reviewer or scanner whose findings enter the ledger. Each writes a `## Concern Delta` section into its own report; the section is read by `concern-ledger stage --from-report`.

- One line per finding: `[<SEV>] <ref> | <repo-relative-path>#<anchor> | <category> | <text>`.
- `<ref>` is the `C<N>` this finding already carries, or `-` when it is new.
- `<anchor>` is the enclosing function, heading, or symbol — stable across edits that shift line numbers.
- Zero findings → the single line `(none)`. An omitted section is not "nothing found".

Each staged round also records how complete that producer's pass was:

| Label | Meaning | Reported as |
|---|---|---|
| `COMPLETE` | The producer swept its whole scope | `PERFORMED` / `COMPLETE` |
| `PARTIAL` | Truncated diff, untrustworthy base, partial scan | `TRUNCATED` / `PARTIAL` / `BASE-*` |
| `ABSENT` | Did not report, or reported nothing readable | anything else |

The round's label is the weaker of the execution label and the parse label (`COMPLETE > PARTIAL > ABSENT`).

## Binding — how a report reaches an existing ID

Applied by `concern-ledger bind`; there are exactly two paths in, and the third is deliberately a dead end.

| Tier | Rule |
|---|---|
| B1 | The producer declared a `C<N>` the ledger holds |
| B2 | The frozen DISCRIM matches an existing entry exactly |
| B3 | Everything else — a NEW ID, never a bind |

Position, ordering, cardinality, and similarity are NOT binding evidence. A reworded restatement therefore does not match B2 by design: silently handing one concern's ID to different text is worse than minting a new one.

## Merging — two producers, one concern

Applied within a single round by `concern-ledger reduce`, over the reports of all producers.

| Tier | Rule | Effect |
|---|---|---|
| M1 | Same declared reference ID | Fold into one entry |
| M2 | Same frozen DISCRIM | Fold into one entry |
| M3 | Same SLOT, exactly one finding per producer | Fold — merge only, never a bind |
| M4 | Same SLOT, more than one from a producer | Keep apart, flag `dup-suspect` |

M3 is the only rule that uses the address, and it is available to merging alone: within one round two producers describing the same place are one concern, but across rounds that inference would be a guess.

## Flags

| Flag | Meaning |
|---|---|
| `merged-slot:<N>` | `<N>` producer wordings folded into this entry |
| `dup-suspect` | Shares a slot with another entry that could not be told apart |
| `ambiguous` | Could not be resolved this round because its slot held rivals |
| `no-anchor` | Reported without an anchor; addressed by its wording alone |
| `stale` | Not reported in the latest round, and that round could not resolve it |
| `reopened` | Was `resolved` and came back |

## The fail-closed rule

An entry may only be resolved by absence when every declared producer for the format reported `COMPLETE` in that round. A round that lost a producer, ran on a truncated diff, or produced an unreadable report resolves nothing: it flags the untouched entries `stale` and leaves them open.

A review that silently drops findings because a scanner crashed is the failure this rule exists to prevent.

## Finalize

When a review ends without converging, `concern-ledger finalize` writes the still-open concerns to `<session-id>-<format>-unresolved-concerns.json` (schema `unresolved-concerns/v1`, terminated by an `"eof"` marker) and snapshots the ledger.

`concern-ledger check-finalized` re-reads that artifact and verifies four things: it exists and is non-empty, its round matches, its schema string is present, and its terminator is intact. Exit 1 means the artifact cannot be trusted.

Callers treat a failed finalize as terminal: `bin/run-codex-review-loop` returns exit 7 in place of the verdict, and a skill that cannot confirm the artifact withholds its completion sentinel. Marking a step complete over concerns nobody can read is the one outcome this pipeline may not produce.

## CLI

`bin/concern-ledger <subcommand>` — every subcommand addresses the ledger by `--plans-dir`, `--session-id`, `--format`.

| Subcommand | Role |
|---|---|
| `begin-round --round N` | Open a new cycle when round 1 meets a live ledger |
| `render-prior` | The still-open concerns, as the block a producer is handed |
| `stage --producer P --from-report F` | Parse one producer's report into this round's delta |
| `reduce --round N` | Bind, merge, and re-state the ledger from the round's deltas |
| `tally` | `open_high=… open_medium=… open_low=… reopened=… resolved=…` |
| `finalize --mode M --reason R --round N` | Write the unresolved-concerns artifact |
| `check-finalized` | Verify that artifact; exit 1 when it cannot be trusted |

Exit codes: 0 ok, 2 usage, 5 finalize could not produce the artifact.
