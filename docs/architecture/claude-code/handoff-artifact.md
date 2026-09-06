# Handoff Artifact

The workflow state file records **which step a session reached**. It cannot record what the session *learned* on the way there — the workaround that finally got a command through, the gate that blocked twice for different reasons, the check that was skipped and why. That knowledge lives only in the conversation, so a compaction or a session boundary destroys it.

The handoff artifact is the durable home for that micro-state: an append-only, human-readable document per session, written by every producer through one function, read back by `/resume-session` when work crosses a session boundary.

## Location and shape

`<PLANS_DIR>/<sid>-handoff.md`, alongside the session's `-intent.md` / `-outline.md` / `-detail.md`. `PLANS_DIR` resolves via `hooks/lib/workflow-plans-dir.js` (`WORKFLOW_PLANS_DIR`, default `~/.workflow-plans`).

The document opens with a title line and `handoff_schema_version: 1`, then one `## <class>` section per class that has entries, in A–G order. Each entry is exactly one line:

`- <at> | <origin> | <step> | <key> | <summary> | <pointer>`

- `at` — ISO-8601 timestamp, written by the writer, never by the caller.
- `origin` — `step-end`, `gate-block`, or `flush`; which of the three producer routes wrote the line.
- `step` — a `VALID_STEPS` member, plus `commit_push` (a skill step the workflow does not track) and `-` (stepless, session-wide entries).
- `key` — the dedup identity within `(class, step)`; matches `^[A-Za-z0-9_.:-]+$`.
- `summary` — one line of prose. The key is identity, not reading matter, so a writer whose key also names the event repeats it at the head of the summary.
- `pointer` — the canonical owner of the full detail, or `-` when none exists.

`\`, `|`, CR and LF are backslash-escaped inside `summary` and `pointer`, so a line never breaks the grammar and never spans two lines.

## Classes

| class | Holds |
|---|---|
| A | Gate blocks — what refused to let the session proceed |
| B | Context events — compaction and other context-lifecycle facts |
| C | User decisions made in conversation that no artifact records |
| D | Deviations — workarounds, fallbacks, scope expansions, flaky results |
| E | Outcomes — sentinels emitted, pushes landed, reports filed |
| F | Open questions carried forward |
| G | Free-form notes |

Per-step schemas exist only for D and E; `skills/_shared/handoff-record.md` owns them. A–C, F and G follow this contract for every step — writing a step-specific format for them would duplicate the contract (CPR-SSOT).

## Writers

`appendHandoffEntry(sid, {cls, step, key, summary, pointer, origin})` in `hooks/lib/handoff-artifact.js` is the only writer. Everything else — the gate, the compaction hook, the skills, `bin/supervisor-report`, the emergency flush — reaches the file through it.

The in/out vocabulary is deliberately asymmetric: a caller passes `cls` (the writer's argument name), read-back exposes `.class` (the document's own field name). This is pinned; it is not an oversight to be smoothed away.

Three producer routes:

| origin | Choke point |
|---|---|
| `step-end` | Skill procedures and CLIs, via `bin/workflow/handoff-append`; also `bin/supervisor-report` on its success path |
| `gate-block` | `function block()` in `hooks/workflow-gate.js`, via `hooks/workflow-gate/handoff-record.js` — the single function all twelve block call sites pass through, with a fixed key `gate:block` |
| `flush` | The emergency flush of `rules/handoff-emergency-flush.md`, and `hooks/post-compact.js` recording the compaction after the fact |

The writer returns `{written, reason}` and **never throws**. Every caller is a side-effect writer whose primary job — deciding a gate verdict, emitting a sentinel, exiting a CLI — must survive a lost breadcrumb, so callers also wrap the call in try/catch and ignore the result. A read-only `PLANS_DIR` changes no existing behavior.

`reason` values: `ok`, `invalid` (bad sid or malformed entry), `noop-identical`, `overflow`, `schema-unknown`, `io`.

### Session id validation

`sid` is validated against `SESSION_ID_VALID_RE` from `hooks/workflow-state/state-io/core.js` before it reaches `path.join`. A hostile sid returns `{written: false, reason: "invalid"}` and the CLI exits non-zero writing nothing — the path is never constructed, so no traversal outside `PLANS_DIR` is reachable (CWE-22).

## Dedup — latest wins

An append is skipped **only** when the immediately preceding line in the same class carries a byte-identical `(origin, step, key, summary, pointer)` tail; that returns `noop-identical`. Any other append lands, including a second entry with the same `(class, step, key)` and a different summary.

That is the point of the rule: a gate that blocks twice for two different reasons must leave two lines, because the audit trail is the artifact's second job. Collapsing to one row per `(step, key)` happens at **render** time, never at write time.

## Reader

- `readHandoff(sid)` → `{exists, schemaVersion, raw, entriesByClass, overflow, sid}`. `entriesByClass` preserves the full append-only history in file order; an unparsable line is dropped, never guessed at. A missing file is `exists: false` — the normal case, not an error.
- `renderHandoffForResume(parsed, {maxEntries})` → the resume view. Within each class it keeps only the maximum-`at` entry per `(step, key)`, renders `- <step> | <summary> | <pointer>`, and stops at `maxEntries` (default 40).

An unknown `handoff_schema_version` is not an error either: the render falls back to showing the document verbatim, because a future writer's document is still human-readable text and refusing to show it would lose more than showing it.

## Caps

400 entry lines or 64KB, whichever comes first. On reaching either, the writer stamps a single `## Overflow` marker into the document and returns `reason: "overflow"`; subsequent appends are refused rather than rotating or truncating, so nothing already recorded is ever lost. The render surfaces the cap to the reader.

## Lifecycle

The artifact is a plan-directory file, so it follows `PLANS_DIR` conventions: no automatic TTL, `bin/sweep-plans.sh` removes it with the rest of its session group after `SWEEP_AGE_DAYS` (default 30, user-initiated), and `bin/session-sync.sh` copies it between machines. State files expire on their own 7-day zombie cleanup, so an artifact routinely outlives the state file it accompanied — `/resume-session --from` treats that as the `artifacts-only` rung of its availability ladder, not as a failure.
