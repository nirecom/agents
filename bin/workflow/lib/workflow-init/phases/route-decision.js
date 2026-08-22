"use strict";

/**
 * Phase: route-decision
 *
 * Runs AFTER meta-classify (#2087) and wip-check. Meta handling — the all-meta
 * sub-issue check and the mixed meta strip — lives in meta-classify.js; this
 * phase only picks the path: META kept as-is, zero issues → C, force_path_b →
 * B, all issues 'intent:clarified' → A, else B.
 */
function routeDecision(state) {
  // meta-classify decided this already, and state.issues still holds the meta
  // issue(s) (never stripped for META — write-context needs them). Without this
  // guard the allClarified check below would run against those issues: a meta
  // issue typically lacks 'intent:clarified', so META would be wrongly
  // overwritten with "B" (M20). The guard also covers force_path_b
  // defense-in-depth (M11) and the degenerate issues===[] shape (M19).
  if (state.path_decision === "META") return { done: false };

  if (state.issues.length === 0) {
    state.path_decision = "C";
    return { done: false };
  }

  if (state.force_path_b) {
    state.path_decision = "B";
    return { done: false };
  }

  const allClarified = state.issues.every((n) =>
    (state.label_sets[n] || []).includes("intent:clarified")
  );

  state.path_decision = allClarified ? "A" : "B";
  return { done: false };
}

module.exports = { routeDecision };
