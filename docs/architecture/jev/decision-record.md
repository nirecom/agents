# Jev Decision Record

Every Jev judgment — the three stage points and the two conversation points —
leaves one JSONL record in `jev-decisions.jsonl` under the log directory,
rotated by size. The log is analysis data, not production state: deleting it
loses only evidence. Overview: [../jev.md](../jev.md).

## Log name and migration

The log was called `jev-decisions.log`. The name changed to
`jev-decisions.jsonl` because it holds cross-point JSONL, like the repository's
other `*.jsonl` logs; `bin/jev-report` reads only the new name.

The first append of a process moves the old file and its rotated generations to
the new name with the same generation numbers, under a lock of its own. It moves
only while no new-name file exists: a new-name file means the move already ran,
or a newer writer started fresh, and the old files are then left for the
operator rather than merged. A failed move leaves the old files in place and is
retried by the next append. The migration is temporary code
(`hooks/lib/temporary-migrations/jev-decision-log-rename.js`) and is deleted
once no host has an old-name file.

## Record version 2

Record version 2 (`version: 2`):

| Field | Meaning |
|---|---|
| `record_type` | `decision`, or `settle` for a superseded ticket's outcome |
| `point` | The judgment point, a registry key |
| `judged_in` | Where the judgment ran, as `{kind, name}`: `hook` or `cli`, and the hook or CLI name; null when unknown |
| `step` | The workflow step current when a conversation point was judged |
| `session_id` | The session the judgment belongs to |
| `ticket` | The CLI ticket; null on a hook record. (`ticket`, `record_type`) is appended at most once |
| `mode`, `threshold`, `short_circuit_answer` | The policy frozen at query time; `threshold` holds both directions |
| `adopted` | Whose answers made the result: `jev`, `llm`, `mixed`, or null |
| `short_circuited`, `unjudged_keys` | Whether the gate short-circuited, and the keys nobody judged because of it |
| `llm_needed` | `query` asked for a subagent dispatch; always false on a conversation point |
| `llm_answer_received` | The ticket's answer file existed at `finalize` |
| `llm.executor` | The backup subagent, taken from the point's registry entry (frozen with the ticket); null on a conversation point |
| `input.required` / `missing` / `exempt` | The stage's required sections and what became of them |
| `input.sources_failed`, `sources_failed_reasons` | Sections with no whole copy, and why (`copy-failed`, `over-cap`) |
| `deterministic` | Computed signals: status, values, overrides, and the sha256 of the list they were computed from |
| `jev.probabilities` | Jev's probability per key, under the point's own key names |
| `agreement_by_signal` | Per key, whether Jev and the subagent agreed — only where both answered |
| `final` | The result, shaped per point (below) |
| `final.unjudged_signals` | Complexity: the signal ids left unjudged by a short circuit — never folded into `final.signals` as absent |
| `fallback_reason` | Why Jev's answer was not used, when it was not; on the CLI finalize path, an unusable answer gives `answer-file-absent` / `answer-empty` / `answer-unparseable`; a source change at settle prints `FALLBACK=source-changed` but records no `fallback_reason` (vocabulary: [two-stage-broker.md](two-stage-broker.md#failure-paths), Missing answer) |

### Where `judged_in` comes from

| Record path | `judged_in` |
|---|---|
| Shadow record | `{kind: "hook", name: "jev-shadow-post"}` |
| Shadow orphan | The pending hand's value; a hand written before the field reads as `jev-shadow-pre` |
| CLI ticket, absent finalize, CLI orphan, settle | The ticket hand's value, `{kind: "cli", name: "jev-judge"}`; an older hand reads the same, since only the CLI makes tickets |
| `continuation` | `{kind: "cli", name: "next-step"}` for wait-on-invoke, `{kind: "hook", name: "stop-premature-stop-guard"}` for continue-on-stop |
| `askuser-answer` | `{kind: "hook", name: "pre-tool-use-askuser-jev"}` |

### `final` of a conversation point

- `continuation`: `{direction, intervene, keys}` — `direction` is
  `wait-on-invoke` or `continue-on-stop`, `keys` the adopted-true keys.
- `askuser-answer`: `{route: "auto-answer", keys: ["q<i>o<j>", ...]}` — one
  chosen key per question — or `{route: "ask-user", keys: []}` when any
  question lacks exactly one confident option. Question text and option labels
  are never recorded; the hook holds the labels in memory only.

A conversation point records nothing while `JEV` is off. Every other outcome,
including no key, an open breaker and a failed query, leaves one record with its
`fallback_reason`.

## Reading the records

The CLI cannot observe an Agent dispatch, only the answer file it leaves — hence
`llm_answer_received`, not a claim that the subagent was called. The report's
**LLM call rate** is the share of decisions with `llm_needed`: how often the CLI
asked for a dispatch. A short-circuited ticket counts in its denominator only.
An orphan recorded as `finalize-absent` counts both as a missing answer and as
an absent finalize. A conversation point counts as adopted only with
`adopted: "jev"`.

Version 1 records (`v: 1`) are the shadow period's hook records. The report
keeps them in a separate legacy section with their original metrics and never
mixes them into adoption or retune figures. A record with neither version key
is counted as unknown.
