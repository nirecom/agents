"use strict";
// Handles the WORKFLOW_CONFIRM_INTENT / _OUTLINE / _DETAIL sentinels.
//
// These sentinels are `permissions.ask` in settings.json — reaching this handler
// means the user explicitly approved the plan stage. That approval is recorded as
// a plan_approvals entry bound to the sha256 of the plan artifact, which is what
// the completion-boundary invariant consults (#1133, #2277).

const {
  CONFIRM_INTENT_RE_DQ,
  CONFIRM_OUTLINE_RE_DQ,
  CONFIRM_DETAIL_RE_DQ,
} = require("../lib/sentinel-patterns");
const {
  computeArtifactSha,
  recordPlanApproval,
  confirmSentinelFor,
} = require("../workflow-state/completion-approval");

const STAGE_PATTERNS = [
  { step: "clarify_intent", re: CONFIRM_INTENT_RE_DQ },
  { step: "outline", re: CONFIRM_OUTLINE_RE_DQ },
  { step: "detail", re: CONFIRM_DETAIL_RE_DQ },
];

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

  let stage = null;
  let m = null;
  for (const p of STAGE_PATTERNS) {
    m = cmd.match(p.re);
    if (m) { stage = p.step; break; }
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
