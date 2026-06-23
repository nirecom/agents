"use strict";
// Handles the CLARIFY_INTENT_COMPLETE sentinel emitted when the clarify-intent
// interview finishes. Marks the clarify_intent step as complete in workflow state.

const { markStep } = require("../lib/workflow-state");
const { CLARIFY_INTENT_COMPLETE_RE_DQ } = require("../lib/sentinel-patterns");

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  // --- CLARIFY_INTENT_COMPLETE handler ---
  if (CLARIFY_INTENT_COMPLETE_RE_DQ.test(cmd)) {
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — clarify_intent NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "clarify_intent", "complete");
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
