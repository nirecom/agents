"use strict";

const { spawnSync } = require("child_process");
const path = require("path");

/**
 * Phase: detect-issues
 * Parse positional CLI args (raw issue tokens like #123, repo#N, owner/repo#N)
 * into issue numbers and populate state.issues + state.repo_map.
 *
 * Returns: { done: false } always (no ask/block from this phase).
 */
function detectIssues(state, tokens, agentsConfigDir) {
  if (!tokens || tokens.length === 0) {
    state.issues = [];
    state.repo_map = {};
    return { done: false };
  }

  // Use parse-issue-tokens (Node script) to safely parse the tokens without shell injection
  const parseScript = path.join(agentsConfigDir, "bin", "parse-issue-tokens");
  const result = spawnSync(process.execPath, [parseScript, ...tokens], {
    encoding: "utf8",
    env: process.env,
  });

  let parsed = [];
  if (result.status === 0 && result.stdout) {
    try {
      parsed = JSON.parse(result.stdout.trim());
    } catch (_e) {
      parsed = [];
    }
  }

  // Build issues list and repo_map from parsed tokens
  const issues = [];
  const repo_map = {};
  for (let i = 0; i < parsed.length; i++) {
    const entry = parsed[i];
    if (entry && typeof entry.number === "number") {
      issues.push(entry.number);
      if (entry.repo) {
        repo_map[i] = entry.repo;
      }
    }
  }

  state.issues = issues;
  state.repo_map = repo_map;
  return { done: false };
}

module.exports = { detectIssues };
