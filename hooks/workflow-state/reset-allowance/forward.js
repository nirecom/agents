"use strict";
// isForwardAt (#2852): was a past RESET_FROM_<target> a move forward? It was when, on the state
// just before it, some step before the target was still owed: not terminal, not settled after the
// table-skip, not an evidence step (its evidence may settle it at read time) and not settled by the
// navigate delivery boundary. Such a reset jumped past owed work, so it went through an ask.

const { VALID_STEPS, TERMINAL_STEPS, isSettledStatus } = require("../state-io");
const { effectiveStatus, EVIDENCE_STEPS, NETWORK_EVIDENCE_STEPS } = require("../effective-state");
const { navigateBoundaryStatus } = require("../effective-state/delivery-boundary");

// settledAt(state, step, profile) — the step's status after table-skip and the navigate boundary.
function settledAt(state, step, profile) {
  const raw = ((state.steps || {})[step] || {}).status || "pending";
  const eff = effectiveStatus(step, raw, profile);
  if (isSettledStatus(eff)) return true;
  return navigateBoundaryStatus(step, eff, state, profile) !== null;
}

function isForwardAt(state, target, profile) {
  if (!state || typeof state !== "object") return false;
  const end = VALID_STEPS.indexOf(target);
  if (end === -1) return false;
  for (let i = 0; i < end; i++) {
    const step = VALID_STEPS[i];
    if (TERMINAL_STEPS.indexOf(step) !== -1) continue;
    if (EVIDENCE_STEPS.indexOf(step) !== -1 || NETWORK_EVIDENCE_STEPS.indexOf(step) !== -1) continue;
    if (!settledAt(state, step, profile)) return true;
  }
  return false;
}

module.exports = { isForwardAt, settledAt };
