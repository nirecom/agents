"use strict";
// Handles RESET_FROM_<step> sentinels, which roll back workflow state to a
// specified step (marking that step and all subsequent steps as pending).

const { validateSkipReason } = require("./skip-reason");
const { RESET_FROM_RE_DQ, RESET_FROM_LOOKSLIKE_RE } = require("../lib/sentinel-patterns");
const { VALID_STEPS, createInitialState, writeState } = require("../lib/workflow-state");

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

  const resetMatch = cmd.match(RESET_FROM_RE_DQ);

  // --- LOOKSLIKE early intercept: catches bare/malformed RESET_FROM forms ---
  if (!resetMatch && RESET_FROM_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed RESET_FROM — ` +
        `expected: echo "<<WORKFLOW_RESET_FROM_<step>: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    return true;
  }

  // --- RESET_FROM handler ---
  if (resetMatch) {
    const [, fromStep, rawReason] = resetMatch;

    const v = validateSkipReason(rawReason);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: RESET_FROM rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_RESET_FROM_${fromStep}: <better reason>>>"`
      );
      return true;
    }

    if (!VALID_STEPS.includes(fromStep)) {
      pushMessage(
        `workflow-mark: ERROR — unknown step "${fromStep}" for RESET_FROM; ` +
        `state NOT changed. Valid steps: ${VALID_STEPS.join(", ")}.`
      );
      return true;
    }

    // #526: pushMessage retained (not signalFatal) — recovery UX must not hard-fail on null sessionId.
    if (!sessionId) {
      pushMessage(
        `workflow-mark: could not resolve session_id — reset-from "${fromStep}" NOT applied. ` +
          `Re-run: echo "<<WORKFLOW_RESET_FROM_${fromStep}: <reason>>>"`
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
