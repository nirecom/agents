# Handoff Artifact

The workflow state file records **which step a session reached**. It cannot record what the session *learned* on the way there — the workaround that finally got a command through, the gate that blocked twice for different reasons, the check that was skipped and why. That knowledge lives only in the conversation, so a compaction or a session boundary destroys it.

The handoff artifact is the durable home for that micro-state: an append-only, human-readable document per session, written by every producer through one function, read back by `/resume-session` when work crosses a session boundary.

## Location and shape

`<PLANS_DIR>/<sid>-handoff.md`, alongside the session's `-intent.md` / `-outline.md` / `-detail.md`. `PLANS_DIR` resolves via `hooks/lib/workflow-plans-dir.js` (`WORKFLOW_PLANS_DIR`, default `~/.workflow-plans`).

The document opens with a title line and `handoff_schema_version: 1`, then one `## <class>` section per class that has entries, in A–G order. Each entry is exactly one line:

`- <at> | <origin> | <step> | <key> | <summary> | <pointer>`

- `at` — ISO-8601 timestamp, written by the writer, never by the caller.
- `origin` — `procedure-point`, `gate-block`, `auto-record`, or `flush`; which producer route wrote the line (see [Writers](#writers)).
- `step` — a `VALID_STEPS` member, plus `commit_push` (a label for `/commit-push`, which is not a workflow step) and `-` (stepless, session-wide entries).
- `key` — the dedup identity within `(class, step)`; matches `^[A-Za-z0-9_.:-]+$`.
- `summary` — one line of prose. The key is identity, not reading matter, so a writer whose key also names the event repeats it at the head of the summary.
- `pointer` — the canonical owner of the full detail, or `-` when none exists.

`\`, `|`, CR and LF are backslash-escaped inside `summary` and `pointer`, so a line never breaks the grammar and never spans two lines.

## Classes

| class | Meaning | Written by |
|---|---|---|
| A | Gate blocks — what refused to let the session proceed | Nobody today: the class is defined, but `gate-block` writes under C (see the note below) |
| B | Context events — compaction and other context-lifecycle facts | `auto-record`: compaction (`hooks/post-compact.js`) |
| C | User decisions made in conversation that no artifact records | Main `flush`, per the flush rule; also the existing `gate-block` route |
| D | Deviations — workarounds, fallbacks, scope expansions, rejected approaches, flaky results | Main `flush`; skill procedures via `procedure-point` (the D rows of `skills/_shared/handoff-record.md`) |
| E | Outcomes — sentinels emitted, pushes landed, reports filed, verdicts | `auto-record`: a successful RESET_FROM sentinel, a supervisor-audit WARN/BLOCK verdict. `procedure-point`: skill procedures and `bin/supervisor-report` |
| F | Open questions carried forward | Main `flush` |
| G | Free-form notes | Nobody by rule; never used for main-session progress notes |

What the main conversation writes (C, D, F) and what it must not write is owned by [`rules/handoff-emergency-flush.md`](../../../rules/handoff-emergency-flush.md) "What to record"; this table only maps each class to its producers.

**Known mismatch.** By definition a gate block is class A, but `recordGateBlock` (`hooks/workflow-gate/handoff-record.js`) writes it with `cls: "C"`, so it sits beside the main session's user decisions. The gate-block route is deliberately unchanged by #2430; re-classing it is a follow-up.

A RESET_FROM is filed under E, not D: the fact recorded is a sentinel that was emitted. The *reason* for deviating stays a D entry the main session writes itself when it matters.

Per-step schemas exist only for D and E; `skills/_shared/handoff-record.md` owns them. A–C, F and G follow this contract for every step — writing a step-specific format for them would duplicate the contract (CPR-SSOT).

## Writers

`appendHandoffEntry(sid, {cls, step, key, summary, pointer, origin})` in `hooks/lib/handoff-artifact.js` is the only writer. Everything else — the gate, the compaction hook, the skills, `bin/supervisor-report`, the emergency flush — reaches the file through it.

The in/out vocabulary is deliberately asymmetric: a caller passes `cls` (the writer's argument name), read-back exposes `.class` (the document's own field name). This is pinned; it is not an oversight to be smoothed away.

### Active-period gate

`appendHandoffEntryIfActive(sid, entry)` in `hooks/lib/handoff-gated-append.js` is the single gate in front of the writer. When `isWorkflowActivePeriod(sid)` is false it returns `{written: false, reason: "inactive"}` and writes nothing; otherwise it returns `appendHandoffEntry`'s result. It never throws.

The **workflow active period** (`hooks/lib/workflow-active-period.js`, total and never-throw) holds when all of these are true: the state file is readable, `workflow_init` is complete, no `TERMINAL_STEPS` member is complete, no `WORKFLOW_OFF` marker is set, and no unexpired `NEXT_STEP_PAUSE` covers the current step. Any error reads as inactive.

Why every origin is gated: the artifact's only reader is `/resume-session`, and outside the active period there is no workflow to resume — a breadcrumb written under `WORKFLOW_OFF` or after `final_report` is noise. A `/commit-push --wip` outcome under `WORKFLOW_OFF`, for example, is already owned by git history.

**The one named exception is `gate-block`.** `recordGateBlock` keeps calling `appendHandoffEntry` directly, because #2430 left the gate-block route unchanged: it is a single hook-written line per block, not a model-driven write. The exception is confined to that one function and pinned by `tests/hooks/feat-2430-handoff-gate-uniform.sh`; whether to fold it into the gate is a follow-up.

**`activeBeforeEvent` is reserved for the reset-from record.** A `RESET_FROM_workflow_init` rolls `workflow_init` back to pending, which ends the active period, so a check made after the reset would always drop that reset's own breadcrumb. `hooks/workflow-mark/reset-handler.js` therefore evaluates the gate before appending the reset events and passes the result as `{ activeBeforeEvent: true }`; the entry is written when the period was active before or after the reset. This is still a gate evaluation, not a bypass, and no other caller passes the option. Pinned by R3 in `tests/hooks/feat-2430-handoff-auto-record.sh`.

### Producer routes

| origin | Choke point | Gated |
|---|---|---|
| `procedure-point` | Skill procedures at their documented record points (`skills/_shared/handoff-record.md`) and scripts, via `bin/workflow/handoff-append`; also `bin/supervisor-report` on its success path | yes |
| `gate-block` | `function block()` in `hooks/workflow-gate.js`, via `hooks/workflow-gate/handoff-record.js` — the single function all twelve block call sites pass through, with a fixed key `gate:block` | **no** (the named exception) |
| `auto-record` | `appendAutoRecord(sid, entry, riskSource)` in `hooks/lib/handoff-auto-record.js` — the only holder of this origin value. Callers: `hooks/post-compact.js` (B, key `compaction`), `hooks/workflow-mark/reset-handler.js` after a successful RESET_FROM (E, key `reset-from`), `bin/supervisor-write-audit-verdict` and `bin/supervisor-write-audit --set-audit-verdict` on a WARN/BLOCK verdict (E, key `supervisor-audit:verdict`) | yes |
| `flush` | The main session's own writes under `rules/handoff-emergency-flush.md`, via `bin/workflow/handoff-append` | yes |

`auto-record` records a fact no model judgment is needed for, and also stamps the matching risk signal (see [Omission-check nudge](#omission-check-nudge)).

**Legacy origins.** Documents written before #2430 carry `step-end` (now `procedure-point`) and record compaction as `flush`. The writer and the CLI accept only the four values above, but the reader never validates `origin`, so an old document reads back unchanged.

The writer returns `{written, reason}` and **never throws**. Every caller is a side-effect writer whose primary job — deciding a gate verdict, emitting a sentinel, exiting a CLI — must survive a lost breadcrumb, so callers also wrap the call in try/catch and ignore the result. A read-only `PLANS_DIR` changes no existing behavior.

`reason` values: `ok`, `invalid` (bad sid or malformed entry), `noop-identical`, `overflow`, `schema-unknown`, `io`, and — from the active-period gate only — `inactive`.

`bin/workflow/handoff-append` sends every origin through the gate. An inactive session prints `WRITTEN=0 REASON=inactive`, explains itself in one stderr line, and exits 0: writing nothing is the intended outcome, not a failure.

### Session id validation

`sid` is validated against `SESSION_ID_VALID_RE` from `hooks/workflow-state/state-io/core.js` before it reaches `path.join`. A hostile sid returns `{written: false, reason: "invalid"}` and the CLI exits non-zero writing nothing — the path is never constructed, so no traversal outside `PLANS_DIR` is reachable (CWE-22).

## Dedup — latest wins

An append is skipped **only** when the immediately preceding line in the same class carries a byte-identical `(origin, step, key, summary, pointer)` tail; that returns `noop-identical`. Any other append lands, including a second entry with the same `(class, step, key)` and a different summary.

That is the point of the rule: a gate that blocks twice for two different reasons must leave two lines, because the audit trail is the artifact's second job. Collapsing to one row per `(step, key)` happens at **render** time, never at write time.

## Reader

- `readHandoff(sid)` → `{exists, schemaVersion, raw, entriesByClass, overflow, sid}`. `entriesByClass` preserves the full append-only history in file order; an unparsable line is dropped, never guessed at. A missing file is `exists: false` — the normal case, not an error.
- `renderHandoffForResume(parsed, {maxEntries})` → the resume view. Within each class it keeps only the maximum-`at` entry per `(step, key)`, renders `- <step> | <summary> | <pointer>`, and stops at `maxEntries` (default 40).

An unknown `handoff_schema_version` is not an error either: the render falls back to showing the document verbatim, because a future writer's document is still human-readable text and refusing to show it would lose more than showing it.

## Omission-check nudge

The flush rule only works when the model notices, on its own, that it holds an unrecorded C/D/F fact. `hooks/handoff-pressure-nudge.js` (UserPromptSubmit) is the second, model-independent layer: it periodically asks the main session to check for such facts. It asks for a *check*, not a write — "nothing to record" is the expected common answer.

Before #2430 the nudge fired whenever the transcript's **total** size exceeded 300KB. Once past that size it re-fired every turn, even right after a flush, and in measured sessions it drove most of all handoff entries — mostly progress snapshots. The nudge now measures **growth since the last check**, and only a check resets it.

### When it fires

Evaluated only when a user prompt is submitted, and only inside the [active period](#active-period-gate) (outside it the hook returns `{}`). No timer process exists; "elapsed" is compared at the next prompt. The triggers are ORed (`TRIGGERS` in `hooks/lib/handoff-pressure.js`):

| trigger | Fires when | Default | After a risk signal |
|---|---|---|---|
| `bytes` | Transcript growth since the baseline ≥ limit | `INCREMENT_BYTES` = 2MiB | 1MiB |
| `elapsed` | Time since the timer start ≥ limit **and** growth since the baseline > 0 | `ELAPSED_MS` = 60 min | 30 min |

The halved column is `limit / RISK_DIVISOR` (2). The growth condition on `elapsed` means an idle session never fires; returning from a break fires once only when unchecked work exists.

The message names the trigger and points at `rules/handoff-emergency-flush.md` "What to record", telling the session to write nothing when there is nothing to record.

### Baseline, flush mark, and timer

- **Baseline** `{baseline_bytes, baseline_at, transcript_path}` — `transcript_path` is the hook-supplied transcript the nudge measured; initialized silently on first evaluation. It moves only when the nudge fires (to the current size and time, written *before* the nudge is emitted — if the write fails the nudge is suppressed, since firing without advancing is the every-turn loop) or when a main-session flush is observed.
- **Flush mark** `{bytes, at}` — written by `bin/workflow/handoff-append` after a successful `--origin flush` write, sized from the baseline's `transcript_path` (`measuredTranscriptPath(sid)`), falling back to `discoverUpstreamTranscript(sid)` when none is recorded or it cannot be stat'ed — discovery takes the first same-SID match across project directories, which may not be the file the nudge measures. A mark newer than the baseline becomes the new baseline and evaluation continues, so growth written after the flush still counts. A mark with `bytes: null` (transcript not found) resets the baseline to the current size without firing.
- `auto-record`, `gate-block`, and `procedure-point` writes never move the baseline: a hook-side write must not silence the main session's check.
- A transcript that shrank re-bases `baseline_bytes` only, without firing.

### Risk signals

A risk signal marks an event after which unrecorded knowledge is most likely to be lost. `recordRiskSignal(sid, source)` (`hooks/lib/handoff-risk-signal.js`) stamps the time; `RISK_SOURCES` is the closed list:

| source | Recorded by |
|---|---|
| `compaction` | `hooks/post-compact.js`, via `appendAutoRecord` |
| `gate-block` | `recordGateBlock` (`hooks/workflow-gate/handoff-record.js`) |
| `reset-from` | `hooks/workflow-mark/reset-handler.js` after a successful RESET_FROM, via `appendAutoRecord` |
| `supervisor-verdict` | The supervisor verdict writers on WARN/BLOCK, via `appendAutoRecord` |
| `supervisor-finding` | `appendFinding` (`hooks/lib/supervisor-state-writer/append.js`) for a finding at or above `AUDIT_SEVERITY_THRESHOLD` |
| `test-failure` | `hooks/workflow-run-tests.js` on a non-zero test exit, except in the steps where red is expected (`write_tests`, `review_tests`, `write_code`) |

The risk state is **derived, never stored**: a stamp newer than `baseline_at` makes the timer start at the stamp and halves both limits. Three properties follow at once — a risk restarts the timer (so a periodic nudge does not land right on top of the event), the halved limits hold until the next nudge or flush, and only a nudge or a flush restores the defaults, because either moves `baseline_at` past the stamp. A risk never moves `baseline_bytes`.

A user's Revise and a tool-permission refusal would also qualify, but have no mechanical record source yet; they are a follow-up.

### Files

All under `PLANS_DIR`, one writer each:

| File | Content | Writer |
|---|---|---|
| `<sid>-handoff-pressure.json` | `{baseline_bytes, baseline_at, transcript_path}` | The nudge hook only |
| `<sid>-handoff-flush-mark.json` | `{bytes, at}` (`bytes` may be null) | `bin/workflow/handoff-append` only |
| `<sid>-handoff-risk.json` | `{last_risk_at, source}` (last writer wins) | `recordRiskSignal` only |

None of them is a handoff write, so none passes the active-period gate; the flush mark exists only after a gated flush succeeded. A failed write never changes a primary outcome: an unwritable baseline suppresses the nudge, an unreadable risk stamp reads as "no risk".

### Why these values

Measured over 98 sessions (21 days, transcripts over 200KB): active transcript growth ran 1.7 / 2.1 / 2.5 / 2.9 MB/h at p25 / p50 / p75 / p90, and useful flushes (C/D) occurred at about 0.76 per hour. The target is one check per hour — the same order as useful flushes, about one check every five turns at the median turn interval. 2MiB is that hour for a median session; 60 minutes (a user decision) caps quiet sessions at the same cadence; the halved values after a risk (also a user decision) double the check density until the next check.

All three are constants. After rollout, measure nudge count, flush count, and the class mix of flushed entries, and revisit the values with the user.

## Caps

400 entry lines or 64KB, whichever comes first. On reaching either, the writer stamps a single `## Overflow` marker into the document and returns `reason: "overflow"`; subsequent appends are refused rather than rotating or truncating, so nothing already recorded is ever lost. The render surfaces the cap to the reader.

## Lifecycle

The artifact is a plan-directory file, so it follows `PLANS_DIR` conventions: no automatic TTL, `bin/sweep-plans.sh` removes it with the rest of its session group after `SWEEP_AGE_DAYS` (default 30, user-initiated), and `bin/session-sync.sh` copies it between machines. State files expire on their own 7-day zombie cleanup, so an artifact routinely outlives the state file it accompanied — `/resume-session --from` treats that as the `artifacts-only` rung of its availability ladder, not as a failure.
