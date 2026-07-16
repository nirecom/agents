"use strict";

/**
 * Phase: closed-detection
 * Check each issue's state from the cache. If any are CLOSED, ask the user
 * to either reopen or remove them.
 *
 * Returns: { done: false } if all open, or
 *          { ask: true, askId: 'closed_reopen_<N>', ... } for first CLOSED issue.
 */
function closedDetection(state) {
  for (const n of state.issues) {
    const data = state.issue_json_cache[n];
    if (!data) continue;
    const issueState = (data.state || "").toUpperCase();
    if (issueState === "CLOSED") {
      return {
        ask: true,
        askId: `closed_reopen_${n}`,
        question: `Issue #${n} is CLOSED. Reopen it to continue, or remove it from this session?`,
        options: "reopen|remove|abort",
      };
    }
  }
  return { done: false };
}

module.exports = { closedDetection };
