"use strict";
// The optional GATE_CONFIRM_<X>=<ON|OFF|ERROR> line of the next-step output.
// Display only: it names the gate of the step NEXT_SKILL invokes; branching is
// decided by `next-step --gate` alone (see gate-mode.js). When the probe cause is
// not ok, a display-only GATE_PROBE_CAUSE=<cause> line sits right before it.

const { confirmGateForStep } = require("../../../../hooks/lib/confirm-gate/step-gate-map");
const { probeConfirmGateWithCause } = require("../../../../hooks/lib/confirm-gate/probe");

// A diagnostic budget, not a cutoff: the in-process probe cannot be aborted, so a
// probe past it keeps its value and is recorded as over-budget (timings: the PR body).
const NEXT_STEP_GATE_PROBE_TIMEOUT_MS = 1500;

function resolveGateLine(step) {
  let key = null;
  try {
    key = confirmGateForStep(step);
    if (!key) return "";
    const r = probeConfirmGateWithCause(key, NEXT_STEP_GATE_PROBE_TIMEOUT_MS);
    const causeLine = r.cause === "ok" ? "" : "GATE_PROBE_CAUSE=" + r.cause + "\n";
    return causeLine + "GATE_" + key + "=" + r.value;
  } catch (_e) {
    return key ? "GATE_PROBE_CAUSE=exception\nGATE_" + key + "=ERROR" : "";
  }
}

module.exports = { resolveGateLine, NEXT_STEP_GATE_PROBE_TIMEOUT_MS };
