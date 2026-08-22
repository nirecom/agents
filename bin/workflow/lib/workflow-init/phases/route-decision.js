"use strict";

// Phase: route-decision. Meta handling lives in meta-classify.js (#2087);
// this phase only picks the path: META kept as-is, zero issues -> C,
// force_path_b -> B, all issues 'intent:clarified' -> A, else B.
function routeDecision(state) {
  // Meta issues lack intent:clarified; don't let that overwrite META with B.
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
