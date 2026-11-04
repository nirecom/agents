"use strict";
// GLOSSARY_AFTER_PUSH advisory line for next-step's verdict (#2909). Once push_branch is recorded
// complete and the change is not delivered, a glossary refusal of a complete plan step no longer
// demotes it (gatedCompleteRefusal); this line names each such step and code, warn-only.

const { RA_STEPS } = require("../../../../hooks/workflow-state/glossary-check/scope");
const { glossaryRefusalErrorOfComplete } = require("../../../../hooks/workflow-state/glossary-check/record");
const { isBranchPushedSession, isPostDeliverySession } = require("../../../../hooks/workflow-state/effective-state/post-delivery");

function glossaryAfterPushNoteLine(state, sid, repoDir) {
  try {
    if (!isBranchPushedSession(state) || isPostDeliverySession(state)) return "";
    const refused = [];
    for (const step of RA_STEPS) {
      const err = glossaryRefusalErrorOfComplete(sid, step, state, { repoDir });
      if (err) refused.push({ step, code: err.code });
    }
    if (refused.length === 0) return "";
    const runs = refused.map((r) => `check-glossary-drift --session ${sid} --step ${r.step} --record`).join(" and ");
    return "GLOSSARY_AFTER_PUSH=" + refused.map((r) => `${r.step}:${r.code}`).join(" ") +
      " warn-only:the PR is open; to align, run " + runs;
  } catch (_) {
    return "";  // advisory only: a read failure never blocks the verdict
  }
}

module.exports = { glossaryAfterPushNoteLine };
