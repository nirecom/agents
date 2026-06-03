"use strict";

const { markStep, nextStepHint } = require("../lib/workflow-state");
const { CLARIFY_INTENT_COMPLETE_RE_DQ } = require("../lib/sentinel-patterns");

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

  // --- CLARIFY_INTENT_COMPLETE handler ---
  if (CLARIFY_INTENT_COMPLETE_RE_DQ.test(cmd)) {
    if (!sessionId) {
      pushMessage(
        `workflow-mark: could not resolve session_id — clarify_intent NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "clarify_intent", "complete");
      const hint = nextStepHint("clarify_intent");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. clarify_intent NOT recorded.`
      );
    }
    return true;
  }

  return false;
}

module.exports = { handle };
