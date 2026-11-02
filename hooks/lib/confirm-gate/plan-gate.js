"use strict";
// hooks/lib/confirm-gate/plan-gate.js — the SSOT of the gate classification of the three plan
// steps (#2650); whether a step is approved or waived is checkPlanApproval's
// (hooks/workflow-state/plan-approval-check.js), which builds on this.
// planGateState(step) -> "ON" | "OFF" | "ERROR": the CONFIRM_* probe combined with the step's
// off waiver. A step the flag cannot waive (clarify_intent) is "ON" without a probe. The probe reads
// the plan step keys from the global config file only (#2729, hooks/lib/config-flag.js).
// The key is the workflow step, never the plan artifact name (#2820): a caller holding an artifact
// name converts it with stepForSuffix first.

const { confirmGateForStep } = require("./step-gate-map");
const { probeConfirmGateSync } = require("./probe");
const { rowFor } = require("../../workflow-state/plan-step-table");
const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../../../bin/workflow/lib/next-step/gate-line");

// planGateFromValue(step, value) -> the step's gate state for a raw probe value.
function planGateFromValue(step, value) {
  const row = rowFor(step);
  if (value === "OFF") return row && row.offWaivable ? "OFF" : "ON";
  return value === "ON" ? "ON" : "ERROR";
}

function planGateState(step, opts) {
  const row = rowFor(step);
  const key = row ? confirmGateForStep(step) : null;
  if (!key) return "ERROR";
  if (!row.offWaivable) return "ON";
  const o = opts || {};
  const timeoutMs = typeof o.timeoutMs === "number" ? o.timeoutMs : NEXT_STEP_GATE_PROBE_TIMEOUT_MS;
  if (!(timeoutMs > 0)) return "ERROR";
  return planGateFromValue(step, probeConfirmGateSync(key, timeoutMs));
}

module.exports = { planGateState, planGateFromValue };
