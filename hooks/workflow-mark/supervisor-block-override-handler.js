"use strict";
// #2709 / #2597 — WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED.
//
//   echo "<<WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED: <run-id> <reason>>>"
// Records the user's reviewed acceptance of a TR5 BLOCK / WARN verdict. settings.json `ask` puts
// every emission through the permission dialog; this handler is the only write path. The retired
// WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED name records nothing: its ask row is gone, so honouring it
// would let an un-dialogued emission write.

const {
  SUPERVISOR_VERDICT_ACCEPTED_RE_DQ,
  SUPERVISOR_VERDICT_ACCEPTED_LOOKSLIKE_RE,
  SUPERVISOR_BLOCK_ACCEPTED_RETIRED_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");
const { recordReviewedVerdictAcceptance, MIN_REASON_LEN } = require("../lib/supervisor-block-override");
const { sanitizeLine } = require("../lib/output-sanitize");

const LABEL = "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED";
const RETIRED_LABEL = "WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED";
const REPORTER = "workflow-mark:supervisor-block-override";
const FORM = `echo "<<${LABEL}: <run-id> <reason>>>"`;

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;
  const m = cmd.match(SUPERVISOR_VERDICT_ACCEPTED_RE_DQ);
  if (m) {
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — ${LABEL} NOT recorded.`);
      return true;
    }
    const runId = m[1];
    const reason = sanitizeLine(m[2].trim());
    let r;
    try {
      r = recordReviewedVerdictAcceptance(sessionId, { runId, reason, reporter: REPORTER });
    } catch (e) {
      pushMessage(`workflow-mark: ${LABEL} failed — ${e.message}; acceptance NOT recorded.`);
      return true;
    }
    if (!r || r.ok !== true) {
      pushMessage(`workflow-mark: ${LABEL} refused — ${(r && r.message) || "unknown error"} Acceptance NOT recorded.`);
      return true;
    }
    pushMessage(`workflow-mark: ${LABEL} recorded — the TR5 verdict for ${runId} is accepted while the code and plan artifacts stay unchanged.`);
    return true;
  }
  if (SUPERVISOR_VERDICT_ACCEPTED_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed ${LABEL} — expected: ${FORM} ` +
        `(<run-id> is run-NNNN; <reason> is at least ${MIN_REASON_LEN} characters without >). Acceptance NOT recorded.`
    );
    return true;
  }
  if (SUPERVISOR_BLOCK_ACCEPTED_RETIRED_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: ${RETIRED_LABEL} was renamed to ${LABEL} and records nothing. ` +
        `Re-issue it as ${FORM} (<reason> is at least ${MIN_REASON_LEN} characters). Acceptance NOT recorded.`
    );
    return true;
  }
  return false;
}

module.exports = { handle };
