"use strict";

const { spawnSync } = require("child_process");
const { buildGhSpawn } = require("../spawn-env");

/**
 * Phase: fetch-issues
 * For each issue number in state.issues, fetch metadata via `gh issue view`.
 * Uses state.issue_json_cache to avoid re-fetching on resume.
 *
 * Returns: { done: false } on success, or
 *          { ask: true, askId: 'fetch_failed_path_c', question, options } on failure.
 */
function fetchIssues(state) {
  for (const n of state.issues) {
    // Skip if already cached
    if (state.issue_json_cache[n] != null) {
      continue;
    }

    // Fetch via gh issue view
    // buildGhSpawn handles Windows/MSYS2 mock detection in test environments
    const ghArgs = ["issue", "view", String(n), "--json", "number,title,body,labels,state,createdAt"];
    const [cmd, args, opts] = buildGhSpawn(ghArgs);
    const result = spawnSync(cmd, args, opts);

    if (result.status !== 0) {
      // Fetch failed → ask_user fetch_failed_path_c
      return {
        ask: true,
        askId: "fetch_failed_path_c",
        question: `Failed to fetch issue #${n}. Continue without this issue (Path C)?`,
        options: "continue|abort",
      };
    }

    let issueData;
    try {
      issueData = JSON.parse(result.stdout.trim());
    } catch (_e) {
      return {
        ask: true,
        askId: "fetch_failed_path_c",
        question: `Failed to parse gh output for issue #${n}. Continue without it (Path C)?`,
        options: "continue|abort",
      };
    }

    state.issue_json_cache[n] = issueData;
  }

  return { done: false };
}

module.exports = { fetchIssues };
