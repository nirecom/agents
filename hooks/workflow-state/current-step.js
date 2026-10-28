"use strict";
// "Which step is this session on right now?" — the cheap, read-only answer.
//
// Distinct from the walk inside bin/workflow/next-step, which needs the full
// reconciled snapshot (git evidence, skip verdicts). Consumers here only need to
// know WHICH step to attribute a dispatch or a pause to, so they stay
// side-effect-free (no git evidence walk). A gated step recorded complete that
// the reconciled view reopens — no verifying approval (#2277 S13) or a refused
// glossary check (#2529, reads the plan artifacts and glossary) — still counts as current.
const { VALID_STEPS, TERMINAL_STEPS, isSettledStatus, readState } = require("./state-io");
const { effectiveStatus, gatedCompleteRefusal } = require("./effective-state");
const { navigateBoundaryStatus } = require("./effective-state/delivery-boundary");

// resolveCurrentStep(state, opts): the first non-terminal step whose EFFECTIVE
// status is not settled, or null when every step is settled. Writes nothing; the
// gated-complete check reads the plan artifacts.
// opts.profile is the caller-resolved session profile; absent → no table-skip.
// opts.repoDir (optional) pins the worktree the glossary check reads.
function resolveCurrentStep(state, opts) {
  const profile = (opts && opts.profile) || null;
  const steps = (state && state.steps) || {};
  for (const step of VALID_STEPS) {
    if (TERMINAL_STEPS.indexOf(step) !== -1) continue;
    const entry = steps[step];
    const raw = (entry && entry.status) || "pending";
    const eff = effectiveStatus(step, raw, profile);
    // #2527: a navigation caller — a delivery-boundary reset reads as settled.
    if (!isSettledStatus(navigateBoundaryStatus(step, eff, state, profile) || eff)) return step;
    if (gatedCompleteRefusal(step, raw, state, opts && opts.sessionId, opts)) return step;
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
    const { resolveSessionProfile } = require("./session-profile");
    return resolveCurrentStep(state, { profile: resolveSessionProfile(state, sid), sessionId: sid });
  } catch (_e) {
    return null;
  }
}

module.exports = { resolveCurrentStep, resolveCurrentEffectiveStep };
