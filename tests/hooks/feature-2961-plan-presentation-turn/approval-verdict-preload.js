"use strict";
// #2961 child preload (NODE_OPTIONS=--require): when CC_APPR_VERDICT is set, checkPlanApproval keeps
// its real answer but reports that verdict (skipped / not-applicable / unknown). next-step --gate
// resolves its step from a readable state file, so these verdicts never reach the outline gate
// through a real fixture; the preload lets the gate child and the stageReadiness child read the
// same verdict on the same session. Loaded before gate-mode.js destructures the export.
const path = require("path");

const V = process.env.CC_APPR_VERDICT;
if (V) {
  const m = require(path.join(__dirname, "..", "..", "..", "hooks", "workflow-state", "plan-approval-check"));
  const real = m.checkPlanApproval;
  m.checkPlanApproval = (sid, step, opts) => Object.assign({}, real(sid, step, opts), { verdict: V, waived: false });
}
