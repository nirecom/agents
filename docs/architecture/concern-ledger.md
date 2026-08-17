# Concern Ledger

What the concern ledger is, and why it is built the way it is. The schema itself, the field list, and the CLI are specified in `skills/_shared/concern-ledger.md` (SSOT) — this document does not repeat them.

## The problem

Every review loop in this repository is multi-round: a reviewer reports, the author responds, the reviewer looks again. Before the ledger, each round produced its own numbering. Round 2's "concern 3" had no relationship to round 1's "concern 3", and a reviewer that reworded a finding produced what looked like a new one.

Three consequences followed, and all three were routinely observed:

- **The author could not tell repetition from novelty.** Every round read as a fresh list, so the natural response was to re-triage findings that had already been triaged.
- **A dropped finding was invisible.** A concern the reviewer simply stopped mentioning disappeared with no record that it had ever been raised, and no way to ask whether it was fixed or forgotten.
- **A second producer could not participate.** `/review-code-security` runs a codex reviewer and a security scanner over the same diff. Two independent numberings over one review is not a review the author can act on.

## What it is

A per-session, per-format text file holding one line per concern, with a stable ID that survives rounds. Rounds do not rewrite it; they are staged as deltas and reduced into it.

The pipeline is deliberately four separable steps — stage, bind, merge, reduce — because they answer four different questions, and conflating them is what makes concern tracking fragile:

| Step | Question |
|---|---|
| stage | What did this one producer say this round, and how complete was its pass? |
| bind | Which of those findings are concerns the ledger already holds? |
| merge | Which of them are the same concern seen by two producers? |
| reduce | Given all of that, what is each concern's state now? |

## Why identity is declared, not inferred

The ledger binds a report to an existing ID on exactly two grounds: the producer named the ID, or the concern's frozen discriminator — a hash of its case-folded, token-sorted text — matches exactly. Nothing else binds.

The rejected alternatives were all forms of inference: same position in the list, same count of findings, similar wording above some threshold. Each fails in the same direction. A wrong bind is silent and permanent: it stamps one concern's history, severity, and round span onto different text, and no later round can detect that it happened. A missed bind is visible and cheap — the author sees one concern twice and says so.

The discriminator is frozen at first sight rather than recomputed, which means a reworded restatement does **not** match. That is the intended behaviour. "The reviewer changed the words" and "the reviewer is talking about something else" are indistinguishable from the outside, and the safe reading of an ambiguous signal is the one that does not overwrite history.

## Why the address is available to merging but not to binding

Each concern carries a SLOT: a hash of file path, anchor, and category — where in the review the concern lives. Within one round, two producers reporting one finding each at the same slot are treated as the same concern. Across rounds, the same coincidence binds nothing.

The asymmetry is about what the evidence supports. Inside a single round the population is closed: two producers looked at one diff at one moment, and one-per-producer at one address is a strong claim of sameness. Across rounds the population is open — the author has edited the code in between, and a new concern at an old address is not just possible, it is the expected result of a fix. Reusing the address as identity would silently absorb new findings into resolved ones.

When a slot holds more than one finding from a single producer, they are kept apart and flagged `dup-suspect`. An unresolvable ambiguity is surfaced rather than guessed.

## Why absence is not resolution

The natural rule — "a concern the reviewer stopped mentioning is fixed" — is correct only when the reviewer actually looked. It is wrong, and dangerously wrong, when the scanner crashed, the diff was truncated, or the merge base was untrustworthy. In those rounds absence means "not examined", and reading it as "fixed" quietly discards findings.

So every staged round carries a three-valued completeness label (`COMPLETE` / `PARTIAL` / `ABSENT`), computed as the weaker of two independent signals: how the producer described its own execution, and how much of its report the parser could read. A producer that claims a clean sweep but emits an unreadable report is not complete.

Resolution by absence requires every declared producer of the format to have reported `COMPLETE`. Anything less leaves the entries open and flags them `stale`. The rule is fail-closed by construction: the failure modes of this system are all "a finding was silently lost", so every ambiguous case resolves toward keeping the concern visible.

## Why a cycle counter instead of renumbering

A round 1 arriving on top of a live ledger means a new review of the same session — a re-run, or a fresh pass after the previous one ended. Renumbering from C1 would collide with IDs the author has already seen in chat and in artifacts.

Instead the header's cycle counter advances. Plan formats archive the old ledger and start an empty ID space; the shared code-review ledger carries its entries forward, because there the two producers' concerns outlive any single invocation of the skill.

## Why finalize is terminal

A review that ends without converging still holds findings the author has not addressed. Those are written to a machine-readable `unresolved-concerns.json` artifact before the ledger is dropped, so the record outlives the loop that produced it.

That write is fail-closed. If the artifact cannot be produced, `bin/run-codex-review-loop` returns exit 7 **instead of** the verdict it would otherwise have returned, and skills withhold their completion sentinel. The alternative — return the verdict, log the write failure, let the step complete — is precisely the failure this whole subsystem exists to prevent: a workflow step marked done over concerns that no longer exist anywhere.

`check-finalized` verifies the artifact independently of the process that wrote it: it exists and is non-empty, its round matches, its schema string is present, and its terminator marker is intact. A partial write from a crash or a full disk fails the check rather than passing as a valid, mostly-empty artifact.

## Two producers, one ledger

`/review-code-security` is the first format with more than one producer. The codex reviewer reaches the ledger through `bin/review-code-ledger`, a wrapper whose stdout is byte-for-byte the reviewer's own output and whose exit status is always 0 — ledger bookkeeping must never be able to block or reshape a review. The security scanner is staged by the skill from the report it writes.

Both are handed the same rendered block of still-open concerns before they run, so "have you seen this before" is answered identically for both, and both are expected to re-report a still-valid concern under the ID it already has.

## Where the code lives

| Path | Role |
|---|---|
| `bin/lib/concern-ledger.sh` | Library entrypoint — the two identity decisions (bind, merge) and every derived file name |
| `bin/lib/concern-ledger/` | The rest of the library: hashing, parsing, reduction, rendering, finalize |
| `bin/concern-ledger` | CLI front end; the only sanctioned entry point |
| `bin/review-code-ledger` | Ledger-aware wrapper around the codex code reviewer |
| `bin/run-codex-review-loop` | Plan/test review loops; owns the exit-7 contract |
| `bin/review-loop-summarize-concerns` | Renders the ledger for the cap-reach dialog |
| `skills/_shared/concern-ledger.md` | Schema and CLI specification (SSOT) |

## Known limits

- Identity is per session. A concern raised in one session and left unresolved has no relationship to the same concern raised in the next.
- The discriminator is exact-match by design, so a rewording produces a new ID. The cost is a duplicate the author can see; the alternative cost is a wrong bind nobody can see.
- Anchors come from the producer. A producer that reports a file with no anchor gets a body-derived slot instead, flagged `no-anchor` — such concerns can merge only on their wording.
