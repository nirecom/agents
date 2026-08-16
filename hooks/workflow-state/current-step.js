"use strict";
// "Which step is this session on right now?" — the cheap, read-only answer.
//
// Distinct from the walk inside bin/workflow/next-step, which needs the full
// reconciled snapshot (git evidence, skip verdicts, approval gates). Consumers
// here only need to know WHICH step to attribute a dispatch or a pause to, so
// they must stay side-effect-free and never touch the repo.
const { VALID_STEPS, TERMINAL_STEPS, isSettledStatus, readState } = require("./state-io");
const { effectiveStatus } = require("./effective-state");

// resolveCurrentStep(state, opts): the first non-terminal step whose EFFECTIVE
// status is not settled, or null when every step is settled. Pure.
function resolveCurrentStep(state, opts) {
  const isWfMeta = !!(opts && opts.isWfMeta);
  const steps = (state && state.steps) || {};
  for (const step of VALID_STEPS) {
    if (TERMINAL_STEPS.indexOf(step) !== -1) continue;
    const entry = steps[step];
    const raw = (entry && entry.status) || "pending";
    if (!isSettledStatus(effectiveStatus(step, raw, isWfMeta))) return step;
  }
  return null;
}

// resolveCurrentEffectiveStep(sid): resolveCurrentStep against the session's
// own state file. Total — a missing, unreadable or corrupt state reads as null,
// never a throw (every consumer is a hook that must not break the user's turn).
function resolveCurrentEffectiveStep(sid) {
  try {
    const state = readState(sid);
    if (!state || !state.steps) return null;
    return resolveCurrentStep(state, { isWfMeta: state.workflow_type === "wf-meta" });
  } catch (_e) {
    return null;
  }
}

module.exports = { resolveCurrentStep, resolveCurrentEffectiveStep };
