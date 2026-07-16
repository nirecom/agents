"use strict";

const fs = require("fs");
const path = require("path");

/**
 * Phase: write-context
 * Write the context.md file to WORKFLOW_PLANS_DIR.
 *
 * Format required (S2 test checks for `## Session metadata` header):
 * ## Session metadata
 * session-id: <sid>
 * timestamp: <ISO>
 * path: <PATH_DECISION>
 * issues: <comma-separated or (none)>
 *
 * ## User initial prompt
 * (none)
 *
 * ## Issue body
 * (body or (none — no issue))
 *
 * ## Issue metadata
 * title: ...
 * state: ...
 * labels: ...
 * createdAt: ...
 *
 * ## Keywords
 * (none)
 */

// WI-9 contract (CWE-77): workflow sentinels must be stripped from untrusted
// third-party issue content (body, title) before it flows into context.md.
// The user initial prompt is in-trust-boundary and is NOT stripped.
const SENTINEL_RE = /<<WORKFLOW_[A-Z_]+[^>]*>>/g;

function stripSentinels(text) {
  return text.replace(SENTINEL_RE, "");
}

function writeContext(state, plansDir, sessionId) {
  const issues = state.issues || [];
  const pathDecision = state.path_decision || "C";
  const timestamp = new Date().toISOString();

  // Build issues line
  const issuesStr = issues.length > 0 ? issues.map((n) => `#${n}`).join(", ") : "(none)";

  // Collect issue data (first issue for body/metadata, or none)
  let bodyStr = "(none — no issue)";
  let titleStr = "(none)";
  let stateStr = "(none)";
  let labelsStr = "(none)";
  let createdAtStr = "(none)";

  if (issues.length > 0) {
    const firstN = issues[0];
    const data = state.issue_json_cache[firstN];
    if (data) {
      bodyStr = stripSentinels(data.body || "(none)");
      titleStr = stripSentinels(data.title || "(none)");
      stateStr = data.state || "(none)";
      labelsStr =
        Array.isArray(data.labels) && data.labels.length > 0
          ? data.labels.map((l) => (typeof l === "string" ? l : l.name || "")).filter(Boolean).join(", ")
          : "(none)";
      createdAtStr = data.createdAt || "(none)";
    }
  }

  const content = [
    `## Session metadata`,
    `session-id: ${sessionId}`,
    `timestamp: ${timestamp}`,
    `path: ${pathDecision}`,
    `issues: ${issuesStr}`,
    ``,
    `## User initial prompt`,
    `(none)`,
    ``,
    `## Issue body`,
    bodyStr,
    ``,
    `## Issue metadata`,
    `title: ${titleStr}`,
    `state: ${stateStr}`,
    `labels: ${labelsStr}`,
    `createdAt: ${createdAtStr}`,
    ``,
    `## Keywords`,
    `(none)`,
    ``,
  ].join("\n");

  const ctxPath = path.join(plansDir, `${sessionId}-context.md`);
  fs.mkdirSync(plansDir, { recursive: true });
  fs.writeFileSync(ctxPath, content, "utf8");

  return { done: false };
}

module.exports = { writeContext };
