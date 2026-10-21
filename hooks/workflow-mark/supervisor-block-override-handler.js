"use strict";
// #2709 — WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED.
//
//   echo "<<WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED: <run-id> <reason>>>"
// Records the user's reviewed override of a standing TR5 BLOCK. settings.json `ask` puts
// every emission through the permission dialog; this handler is the only write path.

const { SUPERVISOR_BLOCK_ACCEPTED_RE_DQ, SUPERVISOR_BLOCK_ACCEPTED_LOOKSLIKE_RE } =
  require("../lib/sentinel-patterns");
const { recordReviewedBlockOverride, MIN_REASON_LEN } = require("../lib/supervisor-block-override");
const { sanitizeLine } = require("../lib/output-sanitize");

const LABEL = "WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED";
const REPORTER = "workflow-mark:supervisor-block-override";
const FORM = `echo "<<${LABEL}: <run-id> <reason>>>"`;

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;
  const m = cmd.match(SUPERVISOR_BLOCK_ACCEPTED_RE_DQ);
  if (m) {
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — ${LABEL} NOT recorded.`);
      return true;
    }
    const runId = m[1];
    const reason = sanitizeLine(m[2].trim());
    let r;
    try {
      r = recordReviewedBlockOverride(sessionId, { runId, reason, reporter: REPORTER });
    } catch (e) {
      pushMessage(`workflow-mark: ${LABEL} failed — ${e.message}; override NOT recorded.`);
      return true;
    }
    if (!r || r.ok !== true) {
      pushMessage(`workflow-mark: ${LABEL} refused — ${(r && r.message) || "unknown error"} Override NOT recorded.`);
      return true;
    }
    pushMessage(`workflow-mark: ${LABEL} recorded — the TR5 BLOCK hold for ${runId} is released while the code and plan artifacts stay unchanged.`);
    return true;
  }
  if (SUPERVISOR_BLOCK_ACCEPTED_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed ${LABEL} — expected: ${FORM} ` +
        `(<run-id> is run-NNNN; <reason> is at least ${MIN_REASON_LEN} characters without >). Override NOT recorded.`
    );
    return true;
  }
  return false;
}

module.exports = { handle };
