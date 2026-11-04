"use strict";
// Issue #2920 — WORKFLOW_ABORT_VERIFIED.
//
//   echo "<<WORKFLOW_ABORT_VERIFIED: <reason>>>"
// Records that the user ended this started workflow without a deliverable (origin abort-sentinel).
// Irreversible; no external writes (gh, wip-state) happen here. The delivered / already-aborted
// refusals are decided inside the state lock by recordWorkflowAborted. Design:
// docs/architecture/claude-code/workflow-abort.md.

const { RE_WORKFLOW_ABORT_VERIFIED_DQ, LOOKSLIKE_WORKFLOW_ABORT_VERIFIED } = require("../lib/sentinel-patterns");
const { isWorkflowStarted } = require("../workflow-state/lifecycle");
const { recordWorkflowAborted } = require("../workflow-state/workflow-abort");
const { sanitizeLine } = require("../lib/output-sanitize");
const { validateSkipReason } = require("./skip-reason");

const LABEL = "WORKFLOW_ABORT_VERIFIED";
const FORM = "echo \"<<WORKFLOW_ABORT_VERIFIED: <reason>>>\" (<reason> must not contain >)";

const REFUSAL = {
  "no-state": "this session has no workflow state",
  "already-aborted": "this session is already aborted; the first abort stands (an abort cannot be undone)",
  delivered: "this session already delivered (merge_to_main is complete); a delivered workflow is not aborted",
};

function handle(ctx) {
  const { cmd, sessionId, pushMessage, pushUnapplied } = ctx;
  const m = cmd.match(RE_WORKFLOW_ABORT_VERIFIED_DQ);
  if (!m) {
    if (!LOOKSLIKE_WORKFLOW_ABORT_VERIFIED.test(cmd)) return false;
    pushUnapplied(`workflow-mark: malformed ${LABEL} — a reason is required. Expected: ${FORM}; state unchanged.`);
    return true;
  }
  const v = validateSkipReason(sanitizeLine(m[1]));
  if (!v.ok) {
    pushUnapplied(`workflow-mark: ${LABEL} rejected — ${v.msg} State unchanged.`);
    return true;
  }
  if (!sessionId) {
    pushUnapplied(`workflow-mark: could not resolve session_id — ${LABEL} NOT recorded.`);
    return true;
  }
  if (!isWorkflowStarted(sessionId)) {
    pushUnapplied(`workflow-mark: ${LABEL} rejected — the workflow has not started (run /workflow-init first); nothing to abort. State unchanged.`);
    return true;
  }
  try {
    const r = recordWorkflowAborted(sessionId, { reason: v.reason, origin: "abort-sentinel" });
    if (!r || !r.recorded) {
      const why = (r && REFUSAL[r.reason]) || `not recorded (${r && r.reason})`;
      pushUnapplied(`workflow-mark: ${LABEL} rejected — ${why}. State unchanged.`);
      return true;
    }
    pushMessage(`[workflow] ${LABEL}: workflow aborted (${v.reason}). Next: next-step points at /worktree-end for the abort cleanup.`);
  } catch (e) {
    pushUnapplied(`workflow-mark: failed to write state — ${e.message}. ${LABEL} NOT recorded.`);
  }
  return true;
}

module.exports = { handle };
