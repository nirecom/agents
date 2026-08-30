"use strict";

const fs = require("fs");
const path = require("path");

const {
  sanitizeInline,
  sanitizeBlock,
  stripSentinels,
  renderCommentsSection,
  renderNoIssueSection,
} = require("../issue-comments");

/**
 * Phase: write-context — writes <session>-context.md into WORKFLOW_PLANS_DIR.
 * Section layout is pinned by tests/feature-workflow-init-driver.
 * Untrusted issue text is sanitized in ../issue-comments.js (CWE-77, WI-9).
 */

// #2063 S4: every issue is fetched, only issues[0] is rendered — the announcement
// tells the reader where the rest went instead of leaving them silently absent.
function multiIssueNote(issues) {
  const others = issues.slice(1).map((n) => `#${n}`).join(", ");
  return `(comments shown for #${issues[0]} only; for ${others} run bin/workflow/render-issue-comments --checkpoint <checkpoint> --issue <number>)`;
}

// #2063 L1-L6: a label name is third-party text like title/state/createdAt, and
// `labels:` is a single line — so each name is sanitized before the join, and the
// join re-stripped because ", " can splice two halves into one live sentinel.
function renderLabels(labels) {
  if (!Array.isArray(labels) || labels.length === 0) return "(none)";
  const names = labels
    .map((l) => (typeof l === "string" ? l : (l && l.name) || ""))
    .filter(Boolean)
    .map((name) => sanitizeInline(name))
    .filter(Boolean);
  return names.length > 0 ? stripSentinels(names.join(", ")) : "(none)";
}

function commentsLines(state, issues) {
  if (issues.length === 0) return renderNoIssueSection().split("\n");
  const cache = state.issue_json_cache;
  const container = cache && typeof cache === "object" && !Array.isArray(cache) ? cache : {};
  const lines = renderCommentsSection(container[issues[0]]).split("\n");
  if (issues.length > 1) lines.splice(1, 0, multiIssueNote(issues), "");
  return lines;
}

function writeContext(state, plansDir, sessionId) {
  const issues = state.issues || [];
  const pathDecision = state.path_decision || "C";
  const timestamp = new Date().toISOString();

  const issuesStr = issues.length > 0 ? issues.map((n) => `#${n}`).join(", ") : "(none)";

  let bodyStr = "(none — no issue)";
  let titleStr = "(none)";
  let stateStr = "(none)";
  let labelsStr = "(none)";
  let createdAtStr = "(none)";

  if (issues.length > 0) {
    const cache = state.issue_json_cache;
    const container = cache && typeof cache === "object" && !Array.isArray(cache) ? cache : {};
    const data = container[issues[0]];
    if (data) {
      bodyStr = sanitizeBlock(data.body || "(none)");
      titleStr = sanitizeInline(data.title || "(none)");
      stateStr = sanitizeInline(data.state || "(none)");
      labelsStr = renderLabels(data.labels);
      createdAtStr = sanitizeInline(data.createdAt || "(none)");
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
  ]
    .concat(commentsLines(state, issues))
    .concat([``, `## Keywords`, `(none)`, ``])
    .join("\n");

  const ctxPath = path.join(plansDir, `${sessionId}-context.md`);
  // C18 fail-closed: a write failure must reach the caller as a blocked outcome,
  // never as an uncaught throw that emits no directive line.
  try {
    fs.mkdirSync(plansDir, { recursive: true });
    fs.writeFileSync(ctxPath, content, "utf8");
  } catch (e) {
    // noCheckpoint: the state carries the third-party text this write just failed to
    // place, and a checkpoint would leave it on disk under a name nothing expects.
    return {
      blocked: true,
      noCheckpoint: true,
      reason: "context_write_failed",
      hint: `Cannot write context.md: ${e.code || "error"}`,
    };
  }

  return { done: false };
}

module.exports = { writeContext };
