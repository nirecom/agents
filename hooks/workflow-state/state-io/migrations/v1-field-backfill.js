"use strict";

// Stage 1 of the state-file migration chain: v1-internal field renames.
//
// These run BEFORE the v1->v2 event conversion (v1-to-v2.js), otherwise the
// generated events would carry retired step names such as `verify` or `plan`
// that are no longer in VALID_STEPS and could never be replayed.
//
// Mutates and returns `state`.
function applyV1FieldBackfill(state) {
  if (!state || typeof state !== "object") return state;

  const steps = state.steps;
  if (steps && typeof steps === "object") {
    // verify -> run_tests rename
    if (steps.verify && !steps.run_tests) steps.run_tests = steps.verify;
    delete steps.verify;
    // `code` was retired outright.
    delete steps.code;

    // branching_decision -> branching_complete rename
    if (steps.branching_decision && !steps.branching_complete) {
      steps.branching_complete = steps.branching_decision;
    }
    delete steps.branching_decision;

    // --- BEGIN temporary: plan → outline+detail migration (added 2026-05-23, #485) ---
    if (steps.plan) {
      const src = steps.plan;
      if (!steps.outline) steps.outline = { ...src };
      if (!steps.detail) steps.detail = { ...src };
      delete steps.plan;
    }
    // --- END temporary: plan → outline+detail migration ---
  }

  if (!state.workflow_type) state.workflow_type = "wf-code";
  // wf-plan -> wf-meta rename
  if (state.workflow_type === "wf-plan") state.workflow_type = "wf-meta";

  return state;
}

module.exports = { applyV1FieldBackfill };
