# Handoff Artifact

The workflow state file records **which step a session reached**. It cannot record what the session *learned* on the way there — the workaround that finally got a command through, the gate that blocked twice for different reasons, the check that was skipped and why. That knowledge lives only in the conversation, so a compaction or a session boundary destroys it.

The handoff artifact is the durable home for that micro-state: an append-only, human-readable document per session, written by every producer through one function, read back by `/resume-session` when work crosses a session boundary, and read (never written) by the supervisor codex engine as review input ([supervisor-codex-input.md](supervisor-codex-input.md)).

## Location and shape

`<WORKFLOW_STATE_DIR>/<sid>.control/handoff.md` — a control file, kept apart from the prose artifacts in `PLANS_DIR` so that it is guarded while `WORKFLOW=on`. The path resolves via `controlPath` in `hooks/workflow-state/state-io/control-dir.js`, which also migrates the legacy session-prefixed `handoff.md` left in `PLANS_DIR`.

The document opens with a title line and `handoff_schema_version: 1`, then one `## <class>` section per class that has entries, in A–G order. Each entry is exactly one line:

`- <at> | <origin> | <step> | <key> | <summary> | <pointer>`

- `at` — ISO-8601 timestamp, written by the writer, never by the caller.
- `origin` — `procedure-point`, `gate-block`, `auto-record`, or `flush`; which producer route wrote the line (see [Writers](#writers)).
- `step` — a `VALID_STEPS` member, plus `commit_push` (the pre-#2527 label for `/commit-push`, now the `push_branch` step; kept so older entries still validate) and `-` (stepless, session-wide entries).
- `key` — the dedup identity within `(class, step)`; matches `^[A-Za-z0-9_.:-]+$`.
- `summary` — one line of prose. The key is identity, not reading matter, so a writer whose key also names the event repeats it at the head of the summary.
- `pointer` — the canonical owner of the full detail, or `-` when none exists.

`\`, `|`, CR and LF are backslash-escaped inside `summary` and `pointer`, so a line never breaks the grammar and never spans two lines.

## Classes

| class | Meaning | Written by |
|---|---|---|
| A | Gate blocks — what refused to let the session proceed | Nobody today: the class is defined, but `gate-block` writes under C (see the note below) |
| B | Context events — compaction and other context-lifecycle facts | `auto-record`: compaction (`hooks/post-compact.js`) |
| C | User decisions made in conversation that no artifact records | Legacy main `flush` (now `session-progress.md`); also the existing `gate-block` route |
| D | Deviations — workarounds, fallbacks, scope expansions, rejected approaches, flaky results | Main `flush`; skill procedures via `procedure-point` (the D rows of `skills/_shared/handoff-record.md`) |
| E | Outcomes — sentinels emitted, pushes landed, reports filed, verdicts | `auto-record`: a successful RESET_FROM sentinel, a supervisor-audit WARN/BLOCK verdict. `procedure-point`: skill procedures and `bin/supervisor-report` |
| F | Open questions carried forward | Main `flush` |
| G | Free-form notes | Nobody by rule; never used for main-session progress notes |

The main conversation's own facts (user decisions, deviations, rejected approaches, open questions) now go to `session-progress.md`, not here: [progress-file.md](progress-file.md) owns them, and `--origin flush` stays accepted only until #2652 retires it. This table only maps each class to its producers.

**Known mismatch.** By definition a gate block is class A, but `recordGateBlock` (`hooks/workflow-gate/handoff-record.js`) writes it with `cls: "C"`, so it sits beside the main session's user decisions. The gate-block route is deliberately unchanged by #2430; re-classing it is a follow-up.

A RESET_FROM is filed under E, not D: the fact recorded is a sentinel that was emitted. The *reason* for deviating stays a D entry the main session writes itself when it matters.

Per-step schemas exist only for D and E; `skills/_shared/handoff-record.md` owns them. A–C, F and G follow this contract for every step — writing a step-specific format for them would duplicate the contract (CPR-SSOT).

## Writers

`appendHandoffEntry(sid, {cls, step, key, summary, pointer, origin})` in `hooks/lib/handoff-artifact.js` is the only writer. Everything else — the gate, the compaction hook, the skills, `bin/supervisor-report`, a legacy `flush` — reaches the file through it.

The in/out vocabulary is deliberately asymmetric: a caller passes `cls` (the writer's argument name), read-back exposes `.class` (the document's own field name). This is pinned; it is not an oversight to be smoothed away.

### Active-period gate

`appendHandoffEntryIfActive(sid, entry)` in `hooks/lib/handoff-gated-append.js` is the single gate in front of the writer. When `isWorkflowActivePeriod(sid)` is false it returns `{written: false, reason: "inactive"}` and writes nothing; otherwise it returns `appendHandoffEntry`'s result. It never throws.

The **workflow active period** (`hooks/lib/workflow-active-period.js`, total and never-throw) holds when all of these are true: the state file is readable, `workflow_init` is complete, no `TERMINAL_STEPS` member is complete, no `WORKFLOW_OFF` marker is set, and no unexpired `NEXT_STEP_PAUSE` covers the current step. Any error reads as inactive.

Why every origin is gated: the artifact's readers are `/resume-session` and the supervisor codex engine, and outside the active period there is no workflow to resume or supervise — a breadcrumb written under `WORKFLOW_OFF` or after `final_report` is noise to both. A `/commit-push --wip` outcome under `WORKFLOW_OFF`, for example, is already owned by git history.

**The one named exception is `gate-block`.** `recordGateBlock` keeps calling `appendHandoffEntry` directly, because #2430 left the gate-block route unchanged: it is a single hook-written line per block, not a model-driven write. The exception is confined to that one function and pinned by `tests/hooks/feat-2430-handoff-gate-uniform.sh`; whether to fold it into the gate is a follow-up.

**`activeBeforeEvent` is reserved for the reset-from record.** A `RESET_FROM_workflow_init` rolls `workflow_init` back to pending, which ends the active period, so a check made after the reset would always drop that reset's own breadcrumb. `hooks/workflow-mark/reset-handler.js` therefore evaluates the gate before appending the reset events and passes the result as `{ activeBeforeEvent: true }`; the entry is written when the period was active before or after the reset. This is still a gate evaluation, not a bypass, and no other caller passes the option. Pinned by R3 in `tests/hooks/feat-2430-handoff-auto-record.sh`.

### Producer routes

| origin | Choke point | Gated |
|---|---|---|
| `procedure-point` | Skill procedures at their documented record points (`skills/_shared/handoff-record.md`) and scripts, via `bin/workflow/handoff-append`; also `bin/supervisor-report` on its success path | yes |
| `gate-block` | `function block()` in `hooks/workflow-gate.js`, via `hooks/workflow-gate/handoff-record.js` — the single function all twelve block call sites pass through, with a fixed key `gate:block` | **no** (the named exception) |
| `auto-record` | `appendAutoRecord(sid, entry, riskSource)` in `hooks/lib/handoff-auto-record.js` — the only holder of this origin value. Callers: `hooks/post-compact.js` (B, key `compaction`), `hooks/workflow-mark/reset-handler.js` after a successful RESET_FROM (E, key `reset-from`), `bin/supervisor-write-audit-verdict` and `bin/supervisor-write-audit --set-audit-verdict` on a WARN/BLOCK verdict (E, key `supervisor-audit:verdict`) | yes |
| `flush` | Legacy main-session writes via `bin/workflow/handoff-append`; no rule asks for them any more (the facts go to [session-progress.md](progress-file.md)), and #2652 retires the origin | yes |

`auto-record` records a fact no model judgment is needed for, and also stamps the matching risk signal (see [progress-file.md](progress-file.md#risk-signals)).

**Legacy origins.** Documents written before #2430 carry `step-end` (now `procedure-point`) and record compaction as `flush`. The writer and the CLI accept only the four values above, but the reader never validates `origin`, so an old document reads back unchanged.

The writer returns `{written, reason}` and **never throws**. Every caller is a side-effect writer whose primary job — deciding a gate verdict, emitting a sentinel, exiting a CLI — must survive a lost breadcrumb, so callers also wrap the call in try/catch and ignore the result. A read-only control dir, or a control-dir migration failure, changes no existing behavior.

`reason` values: `ok`, `invalid` (bad sid or malformed entry), `noop-identical`, `overflow`, `schema-unknown`, `io`, and — from the active-period gate only — `inactive`.

`bin/workflow/handoff-append` sends every origin through the gate. An inactive session prints `WRITTEN=0 REASON=inactive`, explains itself in one stderr line, and exits 0: writing nothing is the intended outcome, not a failure.

### Session id validation

`sid` is validated against `SESSION_ID_VALID_RE` from `hooks/workflow-state/state-io/core.js` before it reaches `path.join`. A hostile sid returns `{written: false, reason: "invalid"}` and the CLI exits non-zero writing nothing — the path is never constructed, so no traversal outside the control dir is reachable (CWE-22).

## Dedup — latest wins

An append is skipped **only** when the immediately preceding line in the same class carries a byte-identical `(origin, step, key, summary, pointer)` tail; that returns `noop-identical`. Any other append lands, including a second entry with the same `(class, step, key)` and a different summary.

That is the point of the rule: a gate that blocks twice for two different reasons must leave two lines, because the audit trail is the artifact's second job. Collapsing to one row per `(step, key)` happens at **render** time, never at write time.

## Reader

- `readHandoff(sid)` → `{exists, schemaVersion, raw, entriesByClass, overflow, sid}`. `entriesByClass` preserves the full append-only history in file order; an unparsable line is dropped, never guessed at. A missing file is `exists: false` — the normal case, not an error.
- `renderHandoffForResume(parsed, {maxEntries})` → the resume view. Within each class it keeps only the maximum-`at` entry per `(step, key)`, renders `- <step> | <summary> | <pointer>`, and stops at `maxEntries` (default 40).

An unknown `handoff_schema_version` is not an error either: the render falls back to showing the document verbatim, because a future writer's document is still human-readable text and refusing to show it would lose more than showing it.

## Omission-check nudge

Replaced by the progress request (#2594): the triggers, the baseline, the risk signals and the measured values now live in [progress-file.md](progress-file.md#omission-check-nudge). `handoff-pressure.json` and `handoff-flush-mark.json` are no longer read or written.

## Caps

400 entry lines or 64KB, whichever comes first. On reaching either, the writer stamps a single `## Overflow` marker into the document and returns `reason: "overflow"`; subsequent appends are refused rather than rotating or truncating, so nothing already recorded is ever lost. The render surfaces the cap to the reader.

## Lifecycle

The artifact is a control file (`<WORKFLOW_STATE_DIR>/<sid>.control/handoff.md`), so it follows the control-directory lifecycle in [state-dirs.md](state-dirs.md) "Cleanup": `bin/sweep-plans.sh` never touches it, and `bin/session-sync.sh` — which copies `PLANS_DIR` files only — does not carry it between machines. State files expire on their own 7-day zombie cleanup while the control directory is kept until its newest file is 30 days old, so an artifact routinely outlives the state file it accompanied — `/resume-session --from` treats that as the `artifacts-only` rung of its availability ladder, not as a failure.
