"use strict";

// #2256 S1-c — SSOT for the audit trigger table and the sub-check registry.
// TR1-TR5 are EDGE triggers on a step-completion transition; TR6 is the one
// LEVEL trigger. Cause labels are unified here so no caller invents its own.

const STEP_COMPLETE_PREFIX = "step-complete:";
const SEVERITY_THRESHOLD_PREFIX = "severity-threshold:";
// The pre-merge gate no longer arms a cause of its own; it backstops freshness.
const FRESHNESS_BACKSTOP_CAUSE = "freshness-backstop:pre-merge";

function stepCompleteCause(step) {
  return `${STEP_COMPLETE_PREFIX}${step}`;
}

// input: "artifact" keys off the named plan artifacts; "diff" keys off the
// working-tree input version.
const SUB_CHECKS = {
  "intent-internal": { input: "artifact", artifacts: ["intent"], earliest_tr: "TR1" },
  "intent-outline": { input: "artifact", artifacts: ["intent", "outline"], earliest_tr: "TR2" },
  "outline-detail": { input: "artifact", artifacts: ["intent", "outline", "detail"], earliest_tr: "TR3" },
  "declared-files-snapshot": { input: "artifact", artifacts: ["detail"], earliest_tr: "TR3" },
  "detail-code": { input: "diff", artifacts: [], earliest_tr: "TR4" },
  "scope-drift": { input: "diff", artifacts: [], earliest_tr: "TR4" },
  "systemic-risk": { input: "diff", artifacts: [], earliest_tr: "TR4" },
  "recurrence-patterns": { input: "diff", artifacts: [], earliest_tr: "TR5" },
};

const ALL_SUB_CHECK_IDS = Object.keys(SUB_CHECKS);

const TRIGGERS = [
  { tr_id: "TR1", kind: "edge", step: "clarify_intent", cause: stepCompleteCause("clarify_intent"), sub_checks: ["intent-internal"] },
  { tr_id: "TR2", kind: "edge", step: "outline", cause: stepCompleteCause("outline"), sub_checks: ["intent-outline"] },
  { tr_id: "TR3", kind: "edge", step: "detail", cause: stepCompleteCause("detail"), sub_checks: ["outline-detail", "declared-files-snapshot"] },
  { tr_id: "TR4", kind: "edge", step: "write_code", cause: stepCompleteCause("write_code"), sub_checks: ["detail-code", "scope-drift", "systemic-risk"] },
  { tr_id: "TR5", kind: "edge", step: "user_verification", cause: stepCompleteCause("user_verification"), sub_checks: ["recurrence-patterns", "detail-code", "scope-drift", "systemic-risk"] },
  { tr_id: "TR6", kind: "level", step: null, cause: `${SEVERITY_THRESHOLD_PREFIX}error`, sub_checks: ALL_SUB_CHECK_IDS.slice() },
];

const EDGE_TRIGGERS_BY_STEP = new Map(
  TRIGGERS.filter((t) => t.kind === "edge").map((t) => [t.step, t])
);

function triggerForStep(step) {
  return EDGE_TRIGGERS_BY_STEP.get(step) || null;
}

function triggerById(trId) {
  return TRIGGERS.find((t) => t.tr_id === trId) || null;
}

// The union of sub-checks a coalesced set of triggers covers, in registry order.
function subChecksForTriggers(trIds) {
  const wanted = new Set();
  for (const id of Array.isArray(trIds) ? trIds : []) {
    const t = triggerById(id);
    if (t) for (const s of t.sub_checks) wanted.add(s);
  }
  return ALL_SUB_CHECK_IDS.filter((id) => wanted.has(id));
}

// TR3 snapshots the declared-files list; the transition key is <step>#<updated_seq>.
function transitionKey(step, updatedSeq) {
  return `${step}#${updatedSeq}`;
}

module.exports = {
  STEP_COMPLETE_PREFIX,
  SEVERITY_THRESHOLD_PREFIX,
  FRESHNESS_BACKSTOP_CAUSE,
  SUB_CHECKS,
  ALL_SUB_CHECK_IDS,
  TRIGGERS,
  stepCompleteCause,
  triggerForStep,
  triggerById,
  subChecksForTriggers,
  transitionKey,
};
