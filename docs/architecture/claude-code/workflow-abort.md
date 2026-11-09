# Workflow abort

A started workflow can end without a deliverable (#2920). Before the abort existed, the only exits were finishing the step table or switching enforcement off, so a dropped task left a session that every Stop guard kept pushing toward delivery. The abort is a recorded session state that the guards read and step aside for.

## Record

- Event kind `workflow_aborted` in the session's own state event stream (`hooks/workflow-state/state-io/events.js`); `reason` is required, and the generic `origin` field holds one of `ABORT_ORIGINS`.
- `downstream_session_id` is required for the scenario B origins and forbidden for `abort-sentinel`.
- Projection (`state-io/projection.js`) folds the first event into `workflow_aborted` (first-wins). `cycle_boundary` and `reset` never clear it, and an event at or below `upstream_copy_seq` is ignored.
- No state version bump and no migration: an older release skips the unknown kind (`default: break`) and reads the session as not aborted.
- Retired field name (#2759): events recorded before the rename carry the session-downstream in the `LEGACY_DOWNSTREAM_FIELD` field (`projection.js`). The projection still reads it from `workflow_aborted` and `workflow_abort_handover` events, inside a temporary migration block.
- Writing that field is refused: `validateEvent` rejects an event carrying it, and the persist step rejects a state holding it anywhere outside those two kinds, so nothing is written. Reading continues. A session refused this way exits by the user deleting that key from its state file, or by starting a new session.

## Predicates and writer

`hooks/workflow-state/workflow-abort.js` owns them; `hooks/workflow-state.js` re-exports them.

- `readWorkflowAbort(sidOrState)` returns the projected value or null.
- `isWorkflowAborted(sid)` is total: an invalid sid or a missing or unreadable state is "not aborted".
- `recordWorkflowAborted(targetSid, {reason, origin, downstreamSid})` refuses `no-state` before taking the lock (so it never creates a state file), and `already-aborted` / `delivered` inside the state lock, so two concurrent triggers record at most one event.
- `selectAbortTargets(downstreamState)` walks the ancestors and returns every one neither aborted nor delivered. Delivered means `merge_to_main` recorded complete, the same test `evaluateResumability` uses.

## Two scenarios

| Scenario | Trigger | `origin` | next-step answer |
|---|---|---|---|
| A — the user drops the work | `/workflow-abort-accepted` emits `<<WORKFLOW_ABORT_ACCEPTED: {reason}>>` (settings `ask`) | `abort-sentinel` | `invoke worktree-end`, `REASON=workflow-aborted-cleanup`, until `cleanup` is settled; then `done`, `REASON=workflow-aborted` |
| B — another session took over | `adoptState` after a successful `/resume-session --from`, or `bin/workflow/adopt-session-state --abort-session-upstreams` | `adopt-auto` / `abort-cli` | `done`, `REASON=workflow-aborted` at once; the worktree and branch belong to the session-downstream |

### A taken over by a session-downstream

An A session still waiting for its cleanup can be adopted: the user, or `/resume-session --from`, moves its work to a new session that now runs in the same worktree. Cleaning up from A would then remove the session-downstream's worktree.

- Both scenario B entry points run `abortUpstreamsFor` (`workflow-abort.js`). After aborting every live session-upstream, it appends a `workflow_abort_handover` event, with `downstream_session_id` naming the session-downstream, to every ancestor whose abort is `abort-sentinel` and names no session-downstream yet (`selectHandoverTargets` / `recordAbortHandover`; refusals `not-aborted` and `already-handed-over` are judged inside the state lock).
- The projection copies that `downstream_session_id` into `workflow_aborted` once. `origin`, `reason` and `seq` stay first-wins, and a handover at or below `upstream_copy_seq` is ignored.
- next-step answers any abort that names a session-downstream with `done`, `REASON=workflow-aborted`, and a hint saying the worktree and branch belong to that session-downstream and are not cleaned up here. This is the scenario B answer, whatever the origin.
- A separate kind keeps `workflow_aborted` a single first-wins record, so an older release reads an adopted A the same way it reads any other abort.

Scenario B needs no sentinel: the user's `--from` is the approval, and the session-downstream's `upstream_session_id` is the evidence. The session-start lineage inheritance does not go through `adoptState`, so it aborts nothing; the explicit CLI recovers that case.

The sentinel handler (`hooks/workflow-mark/workflow-abort-handler.js`) refuses a session that has not started, one already delivered and one already aborted, each with an `UNAPPLIED` reason. It writes nothing outside the state: issue and WIP handling belong to `/worktree-end`'s abort branch (`skills/worktree-end/scripts/abort-branch.md`), which keeps every safety step and deletes the branch only with `branch -d`.

next-step checks its quiet layer in the order paused, workflow-off, aborted (`bin/workflow/lib/next-step/quiet-exits.js`), so a pause or workflow-off marker still wins over the abort.

## Not carried by adoption

`workflow_aborted` and `workflow_abort_handover` are generation-local kinds (`GENERATION_LOCAL_KINDS` in `hooks/workflow-state/inheritance/apply.js`): the copy drops the session-upstream's abort and handover, and unlike state handoff records (`CARRIED_DOWNSTREAM_KINDS`) the session-downstream's own abort does not travel on re-adoption either. An aborted session-upstream therefore stays adoptable, and the session-downstream never starts aborted.

## Irreversible

There is no END sentinel and no undo event. Continuing in the same session would let two sessions touch one worktree and would need its own undo path and record. A mistaken abort is recovered by `/resume-session --from` in a new session.

## Guards that step aside

| Consumer | How |
|---|---|
| C4 premature-stop guard | session-phase row `workflow-aborted`, plus the next-step-output backstop row `workflow-aborted-reason` (REASON starts with `workflow-aborted`) |
| Mechanism-failure detection | `detectStalledSteps` returns `[]`, which also quiets the UserPromptSubmit notice |
| Final-report guard | `shouldYieldOrBypass` exits with `workflow-aborted` for both lanes |
| Supervisor guard | early exit after the paused exit, before C3 and alerts |

Both rows sit in `EXEMPTION_MATRIX` (`hooks/lib/stop-exemption-policy.js`) as `{c4:true, c2:false, nextStep:false, promptNotify:false}`:

- `c4: true` — the rows exist to quiet C4.
- `c2: false` — the supervisor guard quiets as a blanket early exit, like paused and off, not by a per-row C2 exemption.
- `nextStep: false` — after an abort next-step answers `invoke` or `done`, never `paused`.
- `promptNotify: false` — the prompt-side notice goes quiet because the detector returns nothing, not by a row in `PROMPT_NOTIFY_EXEMPTIONS`.
