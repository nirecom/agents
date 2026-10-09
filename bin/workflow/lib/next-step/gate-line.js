"use strict";
// The optional GATE_CONFIRM_<X>=<ON|OFF|ERROR> line of the next-step output.
// Display only: it names the gate of the step NEXT_SKILL invokes; branching is
// decided by `next-step --gate` alone (see gate-mode.js).

const { confirmGateForStep } = require("../../../../hooks/lib/confirm-gate/step-gate-map");
const { probeConfirmGateSync } = require("../../../../hooks/lib/confirm-gate/probe");

// Bounded so the hooks that spawn next-step (3000 ms budget) still finish in time.
const NEXT_STEP_GATE_PROBE_TIMEOUT_MS = 1500;

function resolveGateLine(step) {
  let key = null;
  try {
    key = confirmGateForStep(step);
    if (!key) return "";
    return "GATE_" + key + "=" + probeConfirmGateSync(key, NEXT_STEP_GATE_PROBE_TIMEOUT_MS);
  } catch (_e) {
    return key ? "GATE_" + key + "=ERROR" : "";
  }
}

module.exports = { resolveGateLine, NEXT_STEP_GATE_PROBE_TIMEOUT_MS };
