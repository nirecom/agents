"use strict";

/**
 * Phase: label-extract
 * Extract label names for each issue from the cache and store in state.label_sets.
 *
 * Returns: { done: false } always.
 */
function labelExtract(state) {
  for (const n of state.issues) {
    const data = state.issue_json_cache[n];
    if (!data) {
      state.label_sets[n] = [];
      continue;
    }
    const labels = Array.isArray(data.labels)
      ? data.labels.map((l) => (typeof l === "string" ? l : l.name || "")).filter(Boolean)
      : [];
    state.label_sets[n] = labels;
  }
  return { done: false };
}

module.exports = { labelExtract };
