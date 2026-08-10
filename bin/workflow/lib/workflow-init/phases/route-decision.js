"use strict";

const { spawnSync } = require("child_process");
const { buildGhSpawn, buildGitSpawn } = require("../spawn-env");
const { parseOriginOwnerRepo } = require("../../../../../hooks/lib/parse-remote-url");

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
    // All meta → check sub-issues. Repository identity is resolved once, from
    // the checkout's origin remote, and never per issue (#1899).
    const origin = resolveOwnerRepoFromOrigin();
    if (!origin.ok) {
      return {
        blocked: true,
        reason: "origin_repo_unresolved",
        nextHint:
          "could not resolve the repository from the 'origin' remote: " +
          origin.message +
          ". Run workflow-init from a checkout whose 'origin' remote points at the github.com repository you mean.",
      };
    }
    for (const n of metaIssues) {
      const subIssues = fetchSubIssues(origin.ownerRepo, n);
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

// Repository identity comes from the ORIGIN remote alone — no fallback. The API
// answer can name `upstream` on a fork, and a hardcoded fallback silently points
// every downstream write at a repository nobody asked for (#1899).
function resolveOwnerRepoFromOrigin() {
  const [cmd, args, opts] = buildGitSpawn(["remote", "get-url", "origin"]);
  const result = spawnSync(cmd, args, opts);
  if (result.status !== 0 || !result.stdout) {
    return { ok: false, message: "no 'origin' remote is configured" };
  }
  const url = String(result.stdout).split(/\r?\n/)[0].trim();
  const parsed = parseOriginOwnerRepo(url);
  if (!parsed.ok) return { ok: false, message: parsed.message };
  return { ok: true, ownerRepo: parsed.ownerRepo };
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
