"use strict";
// next-step's quiet layer (#1607, #2920), checked in this order: paused, workflow-off, aborted.
// resolveQuietExit(sid, state) -> { action, skill, hint, reason } | null. Fail-open: an error
// reading a marker or the state yields null so the ordinary walk runs.

const HOOKS = "../../../../hooks";

function pausedOrOff(sid) {
  const { isNextStepPaused, isWorkflowOff } = require(HOOKS + "/lib/session-markers");
  const { resolveCurrentEffectiveStep } = require(HOOKS + "/workflow-state/current-step");
  if (isNextStepPaused(sid, resolveCurrentEffectiveStep(sid))) {
    return {
      action: "paused", skill: "", reason: "next-step-paused",
      hint: "next-step is quiet. Take no workflow action; continue the out-of-workflow work. " +
        "Resume with: echo \"<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>\"",
    };
  }
  if (isWorkflowOff(sid)) {
    return {
      action: "paused", skill: "", reason: "workflow-off-quiet",
      hint: "workflow enforcement is OFF, so next-step is quiet. Take no workflow action. " +
        "Restore with: echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: {reason}>>\" " +
        "(a next-step resume sentinel does NOT clear workflow-OFF)",
    };
  }
  return null;
}

// Scenario A (abort-sentinel) owns its own cleanup until a downstream adopts it; scenario B
// (adopt-auto / abort-cli), or an A taken over by a downstream, hands the worktree to that
// downstream, so it is done at once.
function aborted(sid, state) {
  const { readState, isSettledStatus } = require(HOOKS + "/workflow-state");
  const { readWorkflowAbort } = require(HOOKS + "/workflow-state/workflow-abort");
  const view = state || readState(sid);
  const abort = readWorkflowAbort(view || sid);
  if (!abort) return null;
  if (abort.downstream_session_id) {
    return {
      action: "done", skill: "", reason: "workflow-aborted",
      hint: "This session was aborted (" + abort.origin + "); the worktree and branch belong to the session-downstream " +
        abort.downstream_session_id + " and are not cleaned up here. Take no workflow action here.",
    };
  }
  const cleanup = view && view.steps && view.steps.cleanup;
  if (cleanup && isSettledStatus(cleanup.status)) {
    return { action: "done", skill: "", reason: "workflow-aborted", hint: "This session was aborted and its cleanup is settled." };
  }
  return {
    action: "invoke", skill: "worktree-end", reason: "workflow-aborted-cleanup",
    hint: "This session was aborted. Run /worktree-end via the Skill tool to clean up the worktree and branch.",
  };
}

function resolveQuietExit(sid, state) {
  try {
    const quiet = pausedOrOff(sid);
    if (quiet) return quiet;
  } catch (_e) { /* fail-open */ }
  try {
    return aborted(sid, state);
  } catch (_e) {
    return null;
  }
}

module.exports = { resolveQuietExit };
