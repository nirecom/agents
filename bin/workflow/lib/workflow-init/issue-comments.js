"use strict";

/**
 * #2063: the single renderer for the `## Issue comments` section.
 * Path A (context.md) and Path B (bin/workflow/render-issue-comments) both read
 * from here, so the two artifacts can never drift (CPR-SSOT).
 */

// WI-9 contract (CWE-77): workflow sentinels are stripped from untrusted
// third-party issue content — body, title, comment bodies and comment metadata.
const SENTINEL_RE = /<<WORKFLOW_[A-Z_]+[^>]*>>/g;

// U+0085/U+2028/U+2029 end a line for a Markdown reader but survive a \n-only
// splitter, so a blockquote prefix never reaches the text behind them.
const EXOTIC_BREAK_RE = /[\u0085\u2028\u2029]/g;
const ANY_BREAK_RE = /\r\n|[\n\r\u0085\u2028\u2029]/g;

const HEADING = "## Issue comments";
const UNKNOWN = "(unknown)";
const NO_ISSUE = "(none — no issue)";

// #2063 C14: loop to a fixed point — deleting one token can splice a still-live
// opener back together (a sentinel nested inside another), so re-scan until a
// pass removes nothing.
function stripSentinels(text) {
  if (typeof text !== "string") return "";
  let out = text;
  let prev;
  do {
    prev = out;
    out = out.replace(SENTINEL_RE, "");
  } while (out !== prev);
  return out;
}

// Values interpolated into one line (author, createdAt, issue title): every line
// terminator becomes a space so the value cannot open a second line.
function sanitizeInline(text) {
  return stripSentinels(String(text).replace(ANY_BREAK_RE, " "));
}

// Multi-line values (comment body, issue body): real breaks survive as LF, which
// the blockquote prefix then covers; the rest are flattened.
function sanitizeBlock(text) {
  const unified = String(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  return stripSentinels(unified.replace(EXOTIC_BREAK_RE, " "));
}

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
  const clean = sanitizeBlock(comment.body);
  if (clean === "") return "> (empty comment)";
  return clean
    .split("\n")
    .map((line) => (line === "" ? ">" : `> ${line}`))
    .join("\n");
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
  stripSentinels,
  sanitizeInline,
  sanitizeBlock,
  commentsDefect,
  renderCommentsSection,
  renderNoIssueSection,
};
