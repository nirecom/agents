# Progress File

The workflow state file records **which step a session reached**, and the plan files record **what was planned**. Neither records where the work stands right now, or the decisions, deviations and rejected approaches the conversation produced on the way. A compaction or a session hand-over destroys that knowledge.

`session-progress.md` is the main conversation's own record of it: one Markdown file per workflow, rewritten in place by the model, read back after a compaction, by `/resume-session --from`, and by the supervisor codex engine. Hooks never write its body; they only create it from the template and ask the model to update it (the **progress request**).

The rule the model follows is [`rules/progress-update.md`](../../../rules/progress-update.md); this document owns the design.

## Location and name

`<PLANS_DIR>/<rootSid>-session-progress.md`, resolved through `getPlansArtifactPath(rootSid, "progress")` (`hooks/lib/plans-artifact-registry.js`, artifact kind `progress`). No caller builds the name by hand.

The `session-` part keeps the name apart from topic names that end in `-progress.md`: the registry tries every hyphen split as a sid boundary, so a bare `progress.md` kind made `<sid>-user-requested-project-progress.md` ambiguous.

`rootSid` is the **first generation** of a handed-off session, so every generation keeps writing one file:

- `resolveRootSid(sid)` (`hooks/lib/progress-file.js`) first returns the `root_sid` saved in the session's own `progress-pressure.json`.
- Without one, it walks the inheritance chain: the last backfilled `step_status` event carrying `inherited_from` names the donor. A donor with a saved `root_sid` ends the walk with that value; otherwise the walk continues (depth ≤ 8, cycle-guarded) and ends at the last reachable sid.
- The progress request saves the resolved value on its first evaluation, so later generations copy it instead of walking a chain whose control directories may have expired.

`bin/progress-file path --session <sid>` prints the path; `ensure` also creates the file. Exit 2 is a usage error or an invalid sid.

## Template

`templates/progress.md` holds three sections:

- `Current state` — what is being done and what comes next; rewritten on every update, never a diary.
- `Plan files` — the intent / outline / detail paths, filled in at creation; step state is read from `next-step --list`, never copied.
- `Facts to carry over` — `User decisions`, `Deviations`, `Rejected approaches` (with the reason), `Open questions`.

`ensureProgressFile(sid)` renders the template with exclusive create (`wx`), so a concurrent creator never overwrites a file the model already wrote.

## Writers and readers

| Who | What |
|---|---|
| Main conversation (model) | The body, with Edit, per `rules/progress-update.md` |
| `hooks/progress-nudge.js`, `bin/progress-file ensure` | Creation from the template only |
| `hooks/post-compact.js` | Reads nothing; adds the path line `session-progress.md: <path> (read "Current state" first)` to its context |
| `bin/lib/resume-session/upstream-view.js` | `progress_file: {path, section: "Current state"}` when the upstream's root file exists |
| `hooks/lib/supervisor-codex-input/assemble.js` | The `PROGRESS` block, headed as the model's own record and not evidence ([supervisor-codex-input.md](supervisor-codex-input.md)) |

Subagents never write the file: only the main conversation holds the context the file preserves.

## Sync and recovery

`session-progress.md` is a synced artifact of plan-sync (`syncedArtifactNames()` in the registry), like the plan files. `hooks/show-plan-link.js` records its project host and syncs it silently on every Edit/Write — no plan link, no turn marker, nothing shown — inside the same sync budget as the plans of that call ([plan-sync.md](plan-sync.md)).

Because the model writes the file and the supervisor reads it, a bad write is the main risk. The plan-sync git history is the defence: any earlier version can be restored, and the supervisor block says the content is not evidence.

## Progress request

The request is one `additionalContext` that starts with `[progress check]`, names why it fired, gives the file path, points at `rules/progress-update.md`, and says to continue without writing when nothing changed and to explain nothing to the user. It asks for a *check*, not a write.

`hooks/progress-nudge.js` is registered on three events: `UserPromptSubmit`, `PostToolUse` (matcher `""`) and `Stop`. Its evaluation lives in `hooks/progress-nudge/`.

### Kinds

| Kind | Fires when | Events | Capped |
|---|---|---|---|
| step complete (4a) | A `step_status` `complete` event appears after the event cursor; backfilled and skipped are excluded | PostToolUse Bash / Agent, Stop | no |
| volume (4c) | Transcript growth since the baseline ≥ limit, or elapsed time ≥ limit with growth | UserPromptSubmit, PostToolUse | yes |
| compaction (4d) | The compaction pending flag is set | all three | yes |
| burst | The compaction burst flag is set (below) | all three | no |
| audit arm (4b) | The supervisor audit arms: the arm reason asks to update session-progress.md before launching the audit agent | Stop (supervisor guard) | — |

Several completes seen in one evaluation are listed one line each in one request; each counts as one request. Hook ordering is parallel, so a complete written by `workflow-mark.js` after this hook read the state arrives at the next evaluation — the cursor makes it late, never lost.

### When nothing is emitted

- Outside the workflow active period (see [handoff-artifact.md](handoff-artifact.md#active-period-gate)): nothing moves and nothing is created; the next active evaluation judges everything at once.
- A subagent call (`agent_id` set).
- A `Stop` with `stop_hook_active` — that Stop belongs to a conversation the hook already continued.

### Cap

Volume and compaction share a cap of 2 requests per 60 minutes (`CAP_MAX`, `CAP_WINDOW_MS` in `hooks/progress-nudge/evaluate.js`). A capped compaction clears its pending flag: from the second compaction on, the volume limits govern. Step completes and the burst suggestion never count toward the cap.

### Stop

On `Stop` the request continues the conversation, and Claude Code caps such continuations at eight in a row. The hook emits at Stop only for an unreported complete, the compaction flag or the burst flag, and clears each flag when it emits, so one compaction continues at most one Stop. Volume never fires at Stop.

### Cheap path

`PostToolUse` runs on every tool call, so `hooks/progress-nudge/light.js` decides first, from a few `stat` calls and one small JSON read, whether anything could fire. Bash, Agent and Stop always take the full path. The light check passes on a missing state file, a pending flag, growth ≥ half the byte limit, a shrunken transcript, half the elapsed limit, or a session-progress.md mtime that moved.

## Omission-check nudge

The volume kind (4c). Moved here from the handoff design (#2430) when the request replaced the `[handoff check]` nudge.

### Triggers

`TRIGGERS` in `hooks/lib/progress-pressure.js` are ORed:

| trigger | Fires when | Default | After a risk signal |
|---|---|---|---|
| `bytes` | Transcript growth since the baseline ≥ limit | `INCREMENT_BYTES` = 2MiB | 1MiB |
| `elapsed` | Time since the timer start ≥ limit **and** growth since the baseline > 0 | `ELAPSED_MS` = 60 min | 30 min |

The halved column is `limit / RISK_DIVISOR` (2). The growth condition on `elapsed` means an idle session never fires.

### Baseline

- The **pressure baseline** (`progress-pressure.json`) `{baseline_bytes, baseline_at, transcript_path}` — the point transcript growth and elapsed time are measured from; initialized silently on the first evaluation.
- Any request moves it to the current size and time.
- A session-progress.md mtime newer than `baseline_at` and different from the last seen one (`MTIME_TOLERANCE_MS` = 2ms) means the model updated the file: the baseline moves, `last_update_at` is set and `progress_updates` counts it. The first sighting and the hook's own creation only record the mtime.
- A transcript that shrank re-bases `baseline_bytes` only, without firing.
- Handoff writes (`flush` included) no longer move it; the flush mark of #2430 is retired, and `bin/workflow/handoff-append` writes none.

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

The risk state is **derived, never stored**: a stamp newer than `baseline_at` makes the timer start at the stamp and halves both limits until the baseline moves past it, so a periodic request never lands right on top of the event. A risk never moves `baseline_bytes`. The stamp lives in `<sid>.control/handoff-risk.json` (`{last_risk_at, source}`, last writer wins); an unreadable stamp reads as "no risk".

A user's Revise and a tool-permission refusal would also qualify, but have no mechanical record source yet; they are a follow-up.

### Why these values

Measured over 98 sessions (21 days, transcripts over 200KB): active transcript growth ran 1.7 / 2.1 / 2.5 / 2.9 MB/h at p25 / p50 / p75 / p90, and useful flushes occurred at about 0.76 per hour. The target is one check per hour; 2MiB is that hour for a median session, 60 minutes caps quiet sessions at the same cadence, and the halved values after a risk double the density until the next check.

## Compaction

`hooks/post-compact.js` calls `recordCompaction(sid, now)` (`hooks/lib/progress-compaction.js`) inside the active period:

- The time joins `compactions_at` (the last 20 kept).
- `compaction_pending` is set only on the first compaction since `last_update_at`; later ones are left to the volume limits, already halved by the compaction risk signal.

### Compaction burst

More than `BURST_THRESHOLD` (7) compactions within `BURST_WINDOW_MS` (30 minutes) mean the session can no longer hold its own context. The first time per session, the hook writes one class B auto-record (key `compaction-burst`, the count and the window) and sets `burst_pending`; the next request carries one sentence the model passes to the user — the only user-facing line of the request — suggesting to update session-progress.md and hand over to a new session. `burst_shown`, set together with `burst_pending`, keeps it to once per session.

The threshold is measured (2026-10-16). Source: the class B `compaction` entries in the handoff.md of 37 sessions. For each session we took the highest number of compactions inside any 30-minute window. Those per-session maxima were distributed as follows:

| Max compactions in 30 min | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 11 | 17 | 18 | 23 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Sessions | 1 | 5 | 7 | 8 | 3 | 4 | 3 | 1 | 1 | 1 | 1 | 1 | 1 |

30 of the 37 sessions (81%) stayed at 7 or fewer. A burst is therefore 8 or more. Revisit the threshold with the counts below.

### PreCompact and PostCompact

- PreCompact can not add instructions to the compaction summary, so no PreCompact hook exists; the file survives compaction on disk instead.
- Whether PostCompact's `additionalContext` reaches the model is undocumented. The path line stays as a supplement, and every compaction request goes through the pending flag to the next PostToolUse, UserPromptSubmit or Stop.

## State file

`<WORKFLOW_STATE_DIR>/<sid>.control/progress-pressure.json`, read and merged through `hooks/lib/handoff-sidecar.js` (control kind `progress-pressure`). Timestamps are ISO strings or epoch milliseconds.

| Field | Meaning |
|---|---|
| `baseline_bytes`, `baseline_at`, `transcript_path` | The volume baseline |
| `root_sid`, `progress_path` | The resolved first generation and its file |
| `event_cursor` | The last state event `seq` judged for step completes |
| `requests_at` | Capped request times within the cap window |
| `compaction_pending`, `compactions_at` | The compaction flag and recent compaction times |
| `burst_pending`, `burst_shown` | The burst suggestion flag and its once-per-session mark |
| `last_update_at`, `progress_updates`, `progress_seen_mtime` | Observed model updates of session-progress.md |
| `counts` | `step_complete`, `volume`, `compaction`, `update_progress` |

The old `handoff-pressure.json` and `handoff-flush-mark.json` are not read; they stay registered so a leftover file is never reported as unregistered (removed by #2652).

### Counts

`counts` and `progress_updates` are the data for revisiting the values above and the #2430 design values: how often each kind fires against how often the model actually updated the file. `update_progress` counts `/update-progress` runs (`bin/progress-file ensure --reason update-progress`).

## `/update-progress`

`skills/update-progress/SKILL.md` lets the user force an update: the main conversation ensures the file, rewrites `Current state`, adds unrecorded facts, and shows the path in one line.
