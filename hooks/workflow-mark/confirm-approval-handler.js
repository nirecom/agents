"use strict";
// Handles the WORKFLOW_CONFIRM_OUTLINE / WORKFLOW_CONFIRM_DETAIL sentinels.
//
// These sentinels are `permissions.ask` in settings.json — reaching this handler
// means the user explicitly approved the plan stage. That approval is recorded as
// a plan_approvals entry bound to the sha256 of the plan artifact, which is what
// the completion-boundary invariant in state-io.writeState consults (#1133).
//
// WORKFLOW_CONFIRM_INTENT is NOT an approval-gated stage — it falls through.

const {
  CONFIRM_OUTLINE_RE_DQ,
  CONFIRM_DETAIL_RE_DQ,
} = require("../lib/sentinel-patterns");
const {
  computeArtifactSha,
  recordPlanApproval,
  confirmSentinelFor,
} = require("../workflow-state/completion-approval");

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

  let stage = null;
  let m = cmd.match(CONFIRM_OUTLINE_RE_DQ);
  if (m) {
    stage = "outline";
  } else {
    m = cmd.match(CONFIRM_DETAIL_RE_DQ);
    if (m) stage = "detail";
  }
  if (!stage) return false;

  if (!sessionId) {
    pushMessage(
      `workflow-mark: could not resolve session_id — ${stage} approval NOT recorded. ` +
        `Completion of ${stage} will be refused until it is. ` +
        `Re-run: echo "<<${confirmSentinelFor(stage)}: {summary}>>"`
    );
    return true;
  }

  try {
    const sha = computeArtifactSha(sessionId, stage);
    recordPlanApproval(sessionId, stage, {
      source: "confirm-sentinel",
      reason: m[1],
      artifactSha: sha,
      // A null sha means the plan artifact was unreadable at approval time —
      // a protocol violation. It is recorded honestly and rejected fail-closed
      // later, never downgraded to an existence-only check.
      artifactHashStatus: sha ? "recorded" : "uncomputable-at-record",
    });
    pushMessage(
      `workflow-mark: ${stage} approval recorded (source: confirm-sentinel, ` +
        `hash-status: ${sha ? "recorded" : "uncomputable-at-record"}).`
    );
  } catch (e) {
    pushMessage(
      `workflow-mark: failed to record ${stage} approval — ${e.message}. ` +
        `Completion of ${stage} will be refused. ` +
        `Re-run: echo "<<${confirmSentinelFor(stage)}: {summary}>>"`
    );
  }
  return true;
}

module.exports = { handle };
