"use strict";
// Handles PREMISE_FAIL and PREMISE_ACK sentinels for the premise-contradiction gate.
// PREMISE_FAIL blocks the workflow when a planner premise is invalidated mid-session;
// PREMISE_ACK clears the block once the contradiction is acknowledged.

const { validateSkipReason } = require("./skip-reason");
const {
  PREMISE_FAIL_RE_DQ, PREMISE_FAIL_LOOKSLIKE_RE,
  PREMISE_ACK_RE_DQ, PREMISE_ACK_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");
const {
  setPremiseContradiction, clearPremiseContradiction,
} = require("../lib/workflow-state");

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

  // --- PREMISE_FAIL handler ---
  const premiseFailLooksLike =
    !cmd.match(PREMISE_FAIL_RE_DQ) && PREMISE_FAIL_LOOKSLIKE_RE.test(cmd);
  const premiseFailMatch = cmd.match(PREMISE_FAIL_RE_DQ);
  if (premiseFailLooksLike) {
    pushMessage(
      `workflow-mark: malformed PREMISE_FAIL — ` +
        `expected: echo "<<WORKFLOW_PREMISE_FAIL: SUMMARY>>" ` +
        `(summary must be >=3 non-space chars, no '>')`
    );
    return true;
  }
  if (premiseFailMatch) {
    const v = validateSkipReason(premiseFailMatch[1]);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: PREMISE_FAIL rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_PREMISE_FAIL: <summary>>"`
      );
      return true;
    }
    if (!sessionId) {
      pushMessage(
        `workflow-mark: could not resolve session_id — premise contradiction NOT recorded.`
      );
      return true;
    }
    try {
      setPremiseContradiction(sessionId, v.reason);
      pushMessage(`workflow-mark: premise contradiction recorded.`);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. Premise contradiction NOT recorded.`
      );
    }
    return true;
  }

  // --- PREMISE_ACK handler ---
  const premiseAckLooksLike =
    !PREMISE_ACK_RE_DQ.test(cmd) && PREMISE_ACK_LOOKSLIKE_RE.test(cmd);
  if (premiseAckLooksLike) {
    pushMessage(
      `workflow-mark: malformed PREMISE_ACK — ` +
        `expected: echo "<<WORKFLOW_PREMISE_ACK>>" (no payload)`
    );
    return true;
  }
  if (PREMISE_ACK_RE_DQ.test(cmd)) {
    if (!sessionId) {
      pushMessage(
        `workflow-mark: could not resolve session_id — premise acknowledgement NOT recorded.`
      );
      return true;
    }
    try {
      clearPremiseContradiction(sessionId);
      pushMessage(`workflow-mark: premise contradiction cleared (acknowledged).`);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. Premise acknowledgement NOT recorded.`
      );
    }
    return true;
  }

  return false;
}

module.exports = { handle };
