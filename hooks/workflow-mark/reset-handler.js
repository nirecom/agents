"use strict";
// Handles RESET_FROM_<step> sentinels, which roll back workflow state to a
// specified step (marking that step and all subsequent steps as pending).

const { RESET_FROM_RE_DQ } = require("../lib/sentinel-patterns");
const { VALID_STEPS, createInitialState, writeState } = require("../lib/workflow-state");

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

  const resetMatch = cmd.match(RESET_FROM_RE_DQ);

  // --- RESET_FROM handler ---
  if (resetMatch) {
    const [, fromStep] = resetMatch;

    if (!VALID_STEPS.includes(fromStep)) {
      pushMessage(
        `workflow-mark: unknown step "${fromStep}" for reset-from — ignored.`
      );
      return true;
    }

    if (!sessionId) {
      pushMessage(
        `workflow-mark: could not resolve session_id — reset-from "${fromStep}" NOT applied. ` +
          `Re-run: echo "<<WORKFLOW_RESET_FROM_${fromStep}>>"`
      );
      return true;
    }

    try {
      const newState = createInitialState(sessionId);
      const fromIndex = VALID_STEPS.indexOf(fromStep);
      const now = new Date().toISOString();
      for (let i = 0; i < fromIndex; i++) {
        newState.steps[VALID_STEPS[i]] = { status: "complete", updated_at: now };
      }
      writeState(sessionId, newState);
    } catch (e) {
      pushMessage(`workflow-mark: reset-from failed — ${e.message}.`);
    }
    return true;
  }

  return false;
}

module.exports = { handle };
