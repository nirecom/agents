"use strict";
// The one walk for "the first unsettled step" over a status source (#2852). next-step's verdict,
// advance and --list, and the RESET_FROM gate all take the current step from here, so the gate
// judges against the step next-step would invoke. Distinct from ./current-step.js, the cheap
// raw-plus-effective answer for hooks that must not start git.

const { VALID_STEPS, TERMINAL_STEPS, isSettledStatus } = require("./state-io");

// firstUnsettledStep(statusOf) -> the first non-terminal step whose statusOf(step) is not settled, else null.
function firstUnsettledStep(statusOf) {
  for (const step of VALID_STEPS) {
    if (TERMINAL_STEPS.indexOf(step) !== -1) continue;
    if (!isSettledStatus(statusOf(step))) return step;
  }
  return null;
}

// resolveReconciledCurrentStep(state, sid, { repoDir, profile }) -> { ok, step }.
// The walk runs on the navigate snapshot without network evidence. ok is false when the state
// cannot be read or the snapshot throws; step is null when every step is settled.
function resolveReconciledCurrentStep(state, sid, opts) {
  if (!state || typeof state !== "object" || !state.steps || typeof state.steps !== "object") {
    return { ok: false, step: null };
  }
  try {
    const repoDir = (opts && opts.repoDir) || undefined;
    let profile = opts && opts.profile;
    if (!profile) profile = require("./session-profile").resolveSessionProfile(state, sid, { repoDir });
    const { reconcileEffectiveState } = require("./effective-state");
    const snapshot = reconcileEffectiveState(state, sid, { repoDir, profile, deliveryBoundary: "navigate" });
    if (!snapshot || !snapshot.steps) return { ok: false, step: null };
    return { ok: true, step: firstUnsettledStep((step) => (snapshot.steps[step] || {}).status) };
  } catch {
    return { ok: false, step: null };
  }
}

module.exports = { firstUnsettledStep, resolveReconciledCurrentStep };
