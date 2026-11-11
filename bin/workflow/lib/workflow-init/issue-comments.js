"use strict";

/**
 * #2063: the single renderer for the `## Issue comments` section.
 * Path A (context.md) and Path B (bin/workflow/render-issue-comments) both read
 * from here, so the two artifacts can never drift (CPR-SSOT).
 */

// WI-9 contract (CWE-77): the sanitize helpers live in the shared unit (#2924) and are re-exported.
const {
  SENTINEL_RE,
  EXOTIC_BREAK_RE,
  ANY_BREAK_RE,
  stripSentinels,
  sanitizeInline,
  sanitizeBlock,
  quoteBlock,
} = require("../../../../hooks/lib/untrusted-text-sanitize");

const HEADING = "## Issue comments";
const UNKNOWN = "(unknown)";
const NO_ISSUE = "(none — no issue)";

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

// Container-level defect only: one unusable element never voids the section.
function commentsDefect(issueData) {
  if (issueData == null) return "comments_missing";
  if (issueData.comments === undefined) return "comments_missing";
  if (!Array.isArray(issueData.comments)) return "comments_not_array";
  return null;
}

function authorOf(comment) {
  if (!isPlainObject(comment) || !isPlainObject(comment.author)) return UNKNOWN;
  const login = comment.author.login;
  if (typeof login !== "string" || login === "") return UNKNOWN;
  const clean = sanitizeInline(login);
  return clean === "" ? UNKNOWN : clean;
}

function createdAtOf(comment) {
  if (!isPlainObject(comment)) return UNKNOWN;
  const created = comment.createdAt;
  if (typeof created !== "string" || created === "") return UNKNOWN;
  const clean = sanitizeInline(created);
  return clean === "" ? UNKNOWN : clean;
}

function quoteBody(comment) {
  if (!isPlainObject(comment) || typeof comment.body !== "string") {
    return "> (malformed comment)";
  }
  if (sanitizeBlock(comment.body) === "") return "> (empty comment)";
  return quoteBlock(comment.body);
}

function renderComment(comment, position) {
  const header = `### Comment ${position} — ${authorOf(comment)} (${createdAtOf(comment)})`;
  return `${header}\n${quoteBody(comment)}`;
}

function renderCommentsSection(issueData) {
  const defect = commentsDefect(issueData);
  if (defect) {
    return `${HEADING}\n(comments unavailable — malformed cache entry: ${defect})`;
  }
  const comments = issueData.comments;
  if (comments.length === 0) return `${HEADING}\n(none)`;
  const bodies = comments.map((comment, i) => renderComment(comment, i + 1));
  return `${HEADING}\n${bodies.join("\n\n")}`;
}

function renderNoIssueSection() {
  return `${HEADING}\n${NO_ISSUE}`;
}

module.exports = {
  COMMENTS_HEADING: HEADING,
  SENTINEL_RE,
  EXOTIC_BREAK_RE,
  ANY_BREAK_RE,
  stripSentinels,
  sanitizeInline,
  sanitizeBlock,
  commentsDefect,
  renderCommentsSection,
  renderNoIssueSection,
};
