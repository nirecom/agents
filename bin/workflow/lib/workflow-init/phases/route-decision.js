"use strict";

const { spawnSync } = require("child_process");
const { buildGhSpawn } = require("../spawn-env");

/**
 * Phase: route-decision
 *
 * Route logic:
 * - Zero issues → PATH_DECISION=C
 * - All issues have 'meta' label:
 *   → check sub-issues (gh api repos/OWNER/REPO/issues/N/sub_issues)
 *   → if any open → ask_user meta_select
 *   → else PATH_DECISION=META
 * - Mixed meta/non-meta → strip meta issues, warn, continue with non-meta
 * - If state.force_path_b OR any issue lacks 'intent:clarified' → PATH_DECISION=B
 * - All have 'intent:clarified' → PATH_DECISION=A
 */
function routeDecision(state) {
  const issues = state.issues;

  // Zero issues → Path C
  if (issues.length === 0) {
    state.path_decision = "C";
    return { done: false };
  }

  // Classify issues by meta label
  const metaIssues = issues.filter((n) => {
    const labels = state.label_sets[n] || [];
    return labels.includes("meta");
  });
  const nonMetaIssues = issues.filter((n) => {
    const labels = state.label_sets[n] || [];
    return !labels.includes("meta");
  });

  if (metaIssues.length === issues.length) {
    // All meta → check sub-issues
    for (const n of metaIssues) {
      const ownerRepo = getOwnerRepo(state, n);
      const subIssues = fetchSubIssues(ownerRepo, n);
      const openSubs = subIssues.filter((s) => (s.state || "").toLowerCase() === "open");
      if (openSubs.length > 0) {
        // Build question listing all open sub-issues
        const listText = openSubs.map((s) => `#${s.number}: ${s.title}`).join(" | ");
        const optionsDisplay = openSubs.map((s) => `#${s.number}: ${s.title}`).concat(["abort"]).join("|");
        return {
          ask: true,
          askId: "meta_select",
          question: `Issue #${n} is a meta issue with open sub-issues. Select one to work on: ${listText}`,
          options: optionsDisplay,
        };
      }
    }
    // No open sub-issues
    state.path_decision = "META";
    return { done: false };
  }

  if (metaIssues.length > 0) {
    // Mixed meta/non-meta → strip meta, continue with non-meta
    process.stderr.write(
      `[workflow-init] Stripping ${metaIssues.length} meta issue(s) from session: #${metaIssues.join(", #")}\n`
    );
    state.issues = nonMetaIssues;
  }

  // After possible meta strip, re-check zero
  if (state.issues.length === 0) {
    state.path_decision = "C";
    return { done: false };
  }

  // force_path_b OR any missing intent:clarified → Path B
  if (state.force_path_b) {
    state.path_decision = "B";
    return { done: false };
  }

  const allClarified = state.issues.every((n) => {
    const labels = state.label_sets[n] || [];
    return labels.includes("intent:clarified");
  });

  state.path_decision = allClarified ? "A" : "B";
  return { done: false };
}

function getOwnerRepo(state, issueN) {
  // Use gh repo view to get the default repo name
  const [cmd, args, opts] = buildGhSpawn(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
  const result = spawnSync(cmd, args, opts);
  if (result.status === 0 && result.stdout) {
    return result.stdout.trim();
  }
  return "mockorg/mockrepo";
}

function fetchSubIssues(ownerRepo, issueN) {
  const endpoint = `repos/${ownerRepo}/issues/${issueN}/sub_issues`;
  const [cmd, args, opts] = buildGhSpawn(["api", endpoint]);
  const result = spawnSync(cmd, args, opts);
  if (result.status !== 0 || !result.stdout) return [];
  try {
    const parsed = JSON.parse(result.stdout.trim());
    return Array.isArray(parsed) ? parsed : [];
  } catch (_e) {
    return [];
  }
}

module.exports = { routeDecision };
