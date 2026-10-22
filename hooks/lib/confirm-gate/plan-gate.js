"use strict";
// hooks/lib/confirm-gate/plan-gate.js — the SSOT of the gate classification of the three plan
// stages (#2650); whether a stage is approved or waived is checkPlanApproval's
// (hooks/workflow-state/plan-approval-check.js), which builds on this.
// planGateState(stage) -> "ON" | "OFF" | "ERROR": the CONFIRM_* probe combined with the stage's
// off waiver. A stage the flag cannot waive (intent) is "ON" without a probe. The probe reads the
// plan-stage keys from the global config file only (#2729, hooks/lib/config-flag.js).

const { confirmGateForStep } = require("./step-gate-map");
const { probeConfirmGateSync } = require("./probe");
const { rowFor, stepForSuffix } = require("../../workflow-state/plan-stage-table");
const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../../../bin/workflow/lib/next-step/gate-line");

const rowOf = (stage) => rowFor(stepForSuffix(stage));

// planGateFromValue(stage, value) -> the stage's gate state for a raw probe value.
function planGateFromValue(stage, value) {
  const row = rowOf(stage);
  if (value === "OFF") return row && row.offWaivable ? "OFF" : "ON";
  return value === "ON" ? "ON" : "ERROR";
}

function planGateState(stage, opts) {
  const row = rowOf(stage);
  const key = row ? confirmGateForStep(stepForSuffix(stage)) : null;
  if (!key) return "ERROR";
  if (!row.offWaivable) return "ON";
  const o = opts || {};
  const timeoutMs = typeof o.timeoutMs === "number" ? o.timeoutMs : NEXT_STEP_GATE_PROBE_TIMEOUT_MS;
  if (!(timeoutMs > 0)) return "ERROR";
  return planGateFromValue(stage, probeConfirmGateSync(key, timeoutMs));
}

module.exports = { planGateState, planGateFromValue };
