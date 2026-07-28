"use strict";
// Schema migrations applied to a freshly-parsed state object on every read.
// Entrypoint-private to state-io.js; called from core.js readState().

// Mutates and returns `state`. A state without a `steps` map predates every
// migration below and is returned untouched.
function applyStateMigrations(state) {
  if (!state || !state.steps) return state;

  if (state.steps.verify && !state.steps.run_tests) {
    state.steps.run_tests = state.steps.verify;
  }
  delete state.steps.verify;
  delete state.steps.code;
  if (!state.steps.run_tests) {
    state.steps.run_tests = { status: "pending", updated_at: null };
  }
  if (!state.steps.review_security) {
    state.steps.review_security = { status: "pending", updated_at: null };
  }
  // migration: sessions predating review_tests (issue #833) start it pending.
  if (!state.steps.review_tests) {
    state.steps.review_tests = { status: "pending", updated_at: null };
  }
  // --- BEGIN temporary: old sessions → workflow_init migration (added 2026-05-14) ---
  const ci = state.steps.clarify_intent;
  const ciDone = ci && (ci.status === "complete" || ci.status === "skipped");
  if (!state.steps.workflow_init) {
    state.steps.workflow_init = {
      status: (!ci || ciDone) ? "complete" : "pending",
      updated_at: null,
    };
  }
  // --- END temporary: old sessions → workflow_init migration ---
  if (!state.steps.clarify_intent) {
    state.steps.clarify_intent = { status: "complete", updated_at: null };
  }
  // migration: branching_decision → branching_complete rename
  if (state.steps.branching_decision && !state.steps.branching_complete) {
    state.steps.branching_complete = state.steps.branching_decision;
  }
  delete state.steps.branching_decision;
  if (!state.steps.branching_complete) {
    state.steps.branching_complete = { status: "complete", updated_at: null };
  }
  // --- BEGIN temporary: plan → outline+detail migration (added 2026-05-23, #485) ---
  if (state.steps.plan) {
    const src = state.steps.plan;
    if (!state.steps.outline) state.steps.outline = { ...src };
    if (!state.steps.detail)  state.steps.detail  = { ...src };
    delete state.steps.plan;
  }
  // --- END temporary: plan → outline+detail migration ---
  if (!state.steps.cleanup) {
    state.steps.cleanup = { status: "pending", updated_at: null };
  }
  if (!state.workflow_type) {
    state.workflow_type = "wf-code";
  }
  // migration: wf-plan → wf-meta rename
  if (state.workflow_type === "wf-plan") {
    state.workflow_type = "wf-meta";
  }
  // Convenience view: top-level skip_judgment map keyed by step name.
  // Allows callers to access state.skip_judgment[step] instead of
  // state.steps[step].skip_judgment. Read-only; not persisted.
  state.skip_judgment = {};
  for (const step of Object.keys(state.steps)) {
    const sj = state.steps[step] && state.steps[step].skip_judgment;
    if (sj) state.skip_judgment[step] = sj;
  }

  return state;
}

module.exports = { applyStateMigrations };
