# State Handoff Record

The workflow state file records **which step a session reached**. Some facts that a later session needs are not step state: the compaction that just happened, the gate that blocked twice for different reasons, the supervisor verdict, the check a skill procedure skipped and why. A compacted transcript or a session boundary loses them unless something machine-written keeps them.

A state handoff record is that machine-written fact. It is an event of kind `state_handoff_record`, appended to the session's own state file by hooks and skill procedures, never by the model directly. Two consumers read it: `/resume-session` (`--from` and `--list`) when work crosses a session boundary, and the supervisor codex engine as review input ([supervisor-codex-input.md](supervisor-codex-input.md)).

The main conversation's own facts (user decisions, deviations, rejected approaches, open questions) do not go here: [progress-file.md](progress-file.md) owns them in `session-progress.md`.

## Why the state file

Before #2652 the record was a separate append-only `<sid>.control/handoff.md`. That file had three defects: the append was an unlocked read-modify-write, so concurrent writers dropped entries (#2446); a record written during `NEXT_STEP_PAUSE` was silently discarded (#2578); and a RESET was written twice, once as a `reset` event and once as a handoff line.

The state file already is a sequence-numbered, append-only event stream behind `withStateLock`. Writing the record there through `appendEvents` fixes the lost-write race by construction, and leaves two places for session knowledge: the state file (machine-written state handoff records) and `session-progress.md` (model-written facts).

The state root also stays out of the model's reach: `placement-guard.js` refuses direct writes there, so a misbehaving session cannot rewrite its own gate blocks or audit verdicts.

## Event shape

`hooks/workflow-state/state-io/state-handoff-record-schema.js` owns the kind's fields and limits; `validateEvent` in `events.js` delegates the kind check to it.

| Field | Meaning |
|---|---|
| `cls` | One of the classes A–G below |
| `at_step` | A `VALID_STEPS` member, or `-` for a stepless, session-wide record |
| `record_key` | Dedup identity; matches `^[A-Za-z0-9_.:-]+$`, at most 120 characters |
| `summary` | One line of prose, sanitized and capped at 300 characters |
| `pointer` | The canonical owner of the full detail, or `-` |
| `origin` | `procedure-point`, `gate-block`, or `auto-record`; the last two are hook-only (see [Producer routes](#producer-routes)) |
| `provenance` | `declared` for `procedure-point`, `observed` for the two hook-written origins |
| `at`, `seq` | Timestamp set by the write entry; sequence number set by `appendEvents` |

The record carries no `step` or `key` field, so the generic `VALID_STEPS` check on `step` never applies to it; `at_step` is checked by the kind's own rule.

Projection ignores the kind (`default: break`), so a state handoff record never changes `current`, a gate verdict, or the `next-step` answer.

## Classes

| class | Meaning | Written by |
|---|---|---|
| A | Gate blocks — what refused to let the session proceed | Nobody today: `gate-block` writes under C (see the note below) |
| B | Context events — compaction and other context-lifecycle facts | `auto-record`: compaction (key `compaction`), a compaction burst (key `compaction-burst`); any origin: the overflow marker, under the origin of the record that reached the budget |
| C | Blocks and decisions that no artifact records | `gate-block` (key `gate:block`) |
| D | Deviations — workarounds, fallbacks, scope expansions, flaky results | `procedure-point`: the D rows of `skills/_shared/handoff-record.md` |
| E | Outcomes — sentinels emitted (a RESET_FROM, derived from the `reset` event), pushes landed, reports filed, verdicts | `procedure-point`: skill procedures and `bin/supervisor-report`; `auto-record`: a supervisor-audit WARN/BLOCK verdict |
| F | Open questions carried forward | Nobody since the main conversation's facts moved to `session-progress.md` |
| G | Free-form notes | Nobody by rule |

**Known mismatch.** By definition a gate block is class A, but `recordGateBlock` (`hooks/workflow-gate/handoff-record.js`) writes it under C. #2652 keeps that class so the resume view and the supervisor input read the same as before; re-classing it is a follow-up.

**RESET is not written twice.** The `reset` event is the only source of truth for a RESET. The state handoff reader derives a class E entry with key `reset-from` from each `reset` event of the session, for display only; no writer records a reset.

Per-step schemas exist only for D and E; `skills/_shared/handoff-record.md` owns them. The other classes follow this contract for every step (CPR-SSOT).

## Writers

`appendStateHandoffRecord(sid, {cls, step, key, summary, pointer, origin}, {timeoutMs})` in `hooks/lib/state-handoff-record/write.js` (exported by the `hooks/lib/state-handoff-record.js` barrel) is the one write entry. The recording period, the budget and the redaction therefore hold for every origin at once.

The in/out vocabulary is deliberately asymmetric: a caller passes `cls`, `step` and `key`; the stored event names them `cls`, `at_step` and `record_key`.

### Producer routes

| origin | Choke point |
|---|---|
| `procedure-point` | Skill procedures at their documented record points (`skills/_shared/handoff-record.md`) and scripts, via `bin/workflow/handoff-append`; also `bin/supervisor-report` on its success path (E, key `supervisor-reported`) |
| `gate-block` | `function block()` in `hooks/workflow-gate.js`, via `recordGateBlock` in `hooks/workflow-gate/handoff-record.js` — the single function every block call site passes through, with the fixed key `gate:block` |
| `auto-record` | `appendAutoRecord(sid, entry, riskSource)` in `hooks/lib/auto-record.js`, the only holder of this origin value. Callers: `hooks/post-compact.js` (B, `compaction`), `hooks/lib/progress-compaction.js` on a burst (B, `compaction-burst`), and `recordVerdictBreadcrumb` from `bin/supervisor-write-audit-verdict` and `bin/supervisor-write-audit --set-audit-verdict` (E, `supervisor-audit:verdict`) |

`bin/workflow/handoff-append` accepts only `procedure-point`. `gate-block` and `auto-record` are hook-only: the two hooks above write them straight through `write.js`, and the CLI refuses them with exit 2, because a CLI caller must not be able to produce an `observed` record.

The `flush` origin is retired: it had no caller left once the main conversation's facts moved to `session-progress.md`, so `bin/workflow/handoff-append` refuses it with exit 2. The CLI keeps its name and flags; the "handoff" in it names the state handoff record.

`gate-block` and `auto-record` also stamp a risk signal (`recordRiskSignal` in `hooks/lib/risk-signal.js`); the risk signal, the pressure baseline and the retired flush mark belong to the progress request in [progress-file.md](progress-file.md#omission-check-nudge).

### Recording period

A record is written only inside the recording period: the state file exists, `workflow_init` is complete, and no `TERMINAL_STEPS` member is complete. The check runs inside the state lock, on the projection `appendEvents` hands the builder.

The recording period deliberately ignores `NEXT_STEP_PAUSE` and the `WORKFLOW_OFF` marker (#2578): a long paused task is still workflow work whose blocks and outcomes a later session needs.

The **workflow active period** (`hooks/lib/workflow-active-period.js`) is a different, stricter predicate: the recording period's conditions plus no `WORKFLOW_OFF` marker and no unexpired `NEXT_STEP_PAUSE` covering the current step. It no longer gates any writer here; its remaining callers are the progress request and `hooks/post-compact.js`, which ask it before touching `session-progress.md`.

### Result contract

The entry returns `{written, reason}` and never throws. Every caller is a side-effect writer whose primary job — a gate verdict, a sentinel, a CLI exit — must survive a lost record.

| reason | Meaning |
|---|---|
| `written` | Appended (`recordGateBlock` keeps answering its pre-#2652 `ok`) |
| `invalid` | Bad sid, unknown class or origin, bad step or key, or the reserved overflow key |
| `no-state` | No state file; none is created |
| `outside-period` | Outside the recording period |
| `noop-identical` | Same as the previous record of the class |
| `overflow` | The budget is reached |
| `lock-timeout`, `io-error` | The state lock or the write failed; the entry prints one `[state-handoff] record dropped: <reason> cls=<cls> key=<key>` line on stderr |

`sid` is validated against `SESSION_ID_VALID_RE` before any path is built (CWE-22).

`bin/workflow/handoff-append` prints `WRITTEN=1 REASON=written` on success. For `no-state`, `outside-period`, `noop-identical` and `overflow` it names the reason on one stderr line, prints `WRITTEN=0 REASON=<reason>`, and exits 0: writing nothing is an intended outcome, not a failure. Field errors, a hook-only or retired origin, and an invalid sid exit 2.

The lock timeout is the `appendEvents` default (3000 ms) on every route; hooks do not shorten it. Writers that get the lock never lose a record to each other (#2446).

### Redaction

`summary` and `pointer` pass through `sanitizeUntrustedField` at write time. A key that the sanitizer would change (it looks like a secret) is stored as the fixed key `redacted-key` instead of being dropped, because its redacted form would fail the key rule.

## Dedup — latest wins

An append is skipped **only** when the previous record of the same class carries an identical `(origin, at_step, record_key, summary, pointer)`; that returns `noop-identical`. Any other append lands, including a second record with the same `(cls, at_step, record_key)` and a different summary.

A gate that blocks twice for two reasons leaves two records, because the audit trail is the record's second job. Collapsing to one row per key happens at **render** time, and only in the `--from` view.

## Budget

| Limit | Value | Applies to |
|---|---|---|
| `MAX_FIELD_CHARS` | 300 | `summary`, `pointer` |
| `EVENT_MAX_BYTES` | 2048 | One record |
| `MAX_RECORDS` | 300 | Records per generation |
| `MAX_TOTAL_BYTES` | 65536 | Bytes per generation |

Bytes are counted by `storedEventBytes(event)`: the compact `JSON.stringify` UTF-8 size of the stored form, with a ten-digit `seq` reserved, so the count is the same before and after `appendEvents` assigns the real `seq`. The state file is persisted indented, so its on-disk size is larger than the budget.

A record over `EVENT_MAX_BYTES` has its summary shortened at a character boundary with a trailing `...` until it fits; the total is checked against that shortened size.

Only the session's own records past the copy boundary (`upstream_copy_seq`) count. When the next record would reach `MAX_RECORDS` or exceed `MAX_TOTAL_BYTES`, the entry writes one class B record with the reserved key `state-handoff:overflow` (count and bytes in the summary; origin and `provenance` copied from the triggering record) and refuses every later record with `overflow`. The marker sits outside the budget; since there is only one, the bound still holds.

## Not carried by adoption

`/resume-session --from` copies the session-upstream state into the session-downstream (`hooks/workflow-state/inheritance/apply.js`, `buildCopy`). `excludeGenerationLocalKinds` drops every `state_handoff_record` from the copied events, and `upstream_copy_seq` is the last `seq` after that filter. The session-downstream's own records written before a re-adoption travel with it.

Because no generation inherits another's records, one state file holds at most one generation's budget whatever the depth of the chain. The session-upstream records stay readable in the session-upstream file: the state handoff reader is given that sid.

`adopt.js` leaves the kind out of its overwrite-protection check, so a session-downstream that only wrote records is not treated as having its own progress.

## Readers

All readers go through the state handoff reader `readStateHandoff(sid)` (`hooks/lib/state-handoff-record/read.js`). No reader resolves a state file or a legacy `handoff.md` path itself.

`readStateHandoff(sid)` returns `{entries, errors}` and never throws:

- `entries` — every entry of that session in time order: its own `state_handoff_record` events past the copy boundary, the `reset-from` entries derived from its `reset` events, and, during the migration, its legacy `handoff.md` entries. Every field is sanitized again on read; nothing is folded or capped.
- `errors` — the names of sources that exist but cannot be read (`state`, `legacy-handoff-md`). A missing file is not an error; entries from readable sources are still returned.

Reading is shared; formatting belongs to each reader.

| Reader | Reading session | Session read | Formatting |
|---|---|---|---|
| `/resume-session --from` (`bin/lib/resume-session/upstream-view.js`) | session-downstream | The session-upstream it resumes | `renderStateHandoffForResume`: latest entry per `(cls, at_step, record_key)`, the newest 40 plus every overflow mark (`state-handoff:overflow`, `legacy:overflow`), grouped by class, shown as untrusted data |
| `/resume-session --list` (`hooks/workflow-state/upstream-search.js`) | session-downstream | Each listed session-upstream candidate | None: `state_handoff_records` is the count of reader entries (derived `reset-from` and legacy entries included, so not only state handoff record events); `null` when `errors` is non-empty |
| Supervisor codex engine (`hooks/lib/supervisor-codex-input/assemble.js`) | The audited session | The same session (transcript basename and wsid) | Every entry, one line each, in time order; no folding, only the 128KiB `SUPERVISOR_HANDOFF_MAX_BYTES` cap, dropping the oldest first |

The `--list` count is taken before the `--from` folding, so both views agree on whether a session-upstream has records. `--list` reads only the candidates on the returned page.

`--from` reads the state handoff reader once per `buildUpstreamView`. Every view carries `state_handoff_errors`: the reader's `errors` as-is, `["reader"]` when the reader throws, `[]` otherwise — so, like `--list`'s `null`, an unreadable source is never shown as "no records" while readable entries still render. A session-upstream whose state file has expired but whose legacy `handoff.md` remains still has entries, so its availability stays `ARTIFACTS_ONLY` rather than `NONE`. A `NONE` view whose `state_handoff_errors` names `state` carries `reason: "state-unreadable"`, not `unknown-session`: the session existed, and its state file is damaged.

## Legacy `handoff.md` (migration)

`hooks/lib/state-handoff-record/legacy-handoff-md.js` is the part of the state handoff reader that reads a pre-#2652 `<sid>.control/handoff.md`, falling back to the plans-dir `<sid>-handoff.md`. It is read-only, is required only by `read.js`, and is wrapped whole in a Migration Code Block; its deletion condition is that 30 days have passed since the merge, no control dir still holds a legacy `handoff.md`, and the plans dir holds no `<sid>-handoff.md`. Read-only means nothing moves the plans-dir copy, so check it explicitly.

- A session with both a state file and a legacy `handoff.md` returns both, merged by time.
- With a readable state file, the legacy class E `reset-from` lines are dropped, because the `reset` event already yields them; without a state file they are the only source and stay.
- A legacy `## Overflow` marker becomes a class B `legacy:overflow` entry. An unknown or missing schema version is returned as one class B `legacy:unknown-schema` entry whose pointer holds the sanitized raw text.

`hooks/workflow-state/upstream-search.js` keeps its own temporary branch that indexes a plans-dir `<sid>-handoff.md` by sid. Removing the migration code makes legacy entries disappear from all three readers at once.

## Lifecycle

The records live in the state file, so they follow its retention: `STATE_RETENTION_DAYS` in `hooks/workflow-state/state-io/zombie-cleanup.js` equals the control-dir retention of 30 days ([state-dirs.md](state-dirs.md) "Cleanup"). The state file is outside `bin/session-sync.sh`, so records do not travel between machines.

Every write extends the state file's last activity, since cleanup looks at every event's `at`. That cannot keep a finished session alive: records are written only inside the recording period.
