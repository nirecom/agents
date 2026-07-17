"use strict";

// Single source of truth for ## Issues parsing (new SSOT per #548).
// Falls back to legacy ## closes_issues only when ## Issues heading is wholly absent.
// Code-level consumers (require this module):
//   - bin/parse-closes-issues (CLI wrapper)
//   - bin/parse-issue-tokens (CLI wrapper for token parsing)
// Prose/prompt references (pointer comments only — no require):
//   - skills/commit-push, issue-close-stage, issue-close-finalize
//
// Return type: Array<{number: number, repo?: string}>
//   - Local issue:      { number: 42 }           (no repo field)
//   - Short cross-repo: { number: 42, repo: "my-private-repo" }
//   - Full cross-repo:  { number: 42, repo: "nirecom/my-private-repo" }
// Normalization is lazy — stored as-received; full owner/repo is resolved at
// call site via `gh repo view` when needed.

const fs = require("fs");

// Shared token-body regex. Matches the issue-reference body (without list prefix).
// Group 1: repo slug (e.g. "owner/repo" or "repo"), or undefined for local issues.
// Group 2: issue number digits.
// Accepts: #N, repo#N, owner/repo#N, N (bare legacy), and optional ": <title>" suffix.
const ISSUE_TOKEN_BODY_RE = /^(?:([a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)?)#|#)?(\d+)(?:.*)?$/;

// CLI guard: token must contain '#' immediately before digits.
// Rejects bare digit strings and decimal numbers (e.g. "3.2", "42").
const ISSUE_TOKEN_CLI_GUARD_RE = /^(?:[a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)?)?#\d/;

function collectEntries(lines, headingRe) {
  let inSection = false;
  const entries = [];
  for (const line of lines) {
    if (headingRe.test(line)) {
      inSection = true;
      continue;
    }
    if (inSection && /^## /.test(line)) break;
    if (inSection) {
      // Accept:
      //   "- #123"                     → local issue
      //   "- #123: <title>"            → local issue with title
      //   "- 123"                      → local issue (bare number, legacy)
      //   "- repo#123"                 → cross-repo (short)
      //   "- repo#123: <title>"        → cross-repo (short) with title
      //   "- owner/repo#123"           → cross-repo (full)
      //   "- owner/repo#123: <title>"  → cross-repo (full) with title
      //
      // Strip the "- " list prefix, then apply shared ISSUE_TOKEN_BODY_RE.
      const stripped = line.replace(/^-\s+/, "").trimEnd();
      const m = stripped.match(ISSUE_TOKEN_BODY_RE);
      if (m && m[2]) {
        const entry = { number: Number(m[2]) };
        if (m[1]) entry.repo = m[1];
        entries.push(entry);
      }
    }
  }
  return entries;
}

// Parse a single issue token string (e.g. "#123", "repo#123", "owner/repo#123", "123").
// Returns {number: N, repo?: string} on match, null if not a valid token.
function parseIssueToken(token) {
  const t = (token || "").trim();
  if (!ISSUE_TOKEN_CLI_GUARD_RE.test(t)) return null;
  const m = t.match(ISSUE_TOKEN_BODY_RE);
  if (!m || !m[2]) return null;
  const result = { number: parseInt(m[2], 10) };
  if (m[1]) result.repo = m[1];
  return result;
}

function parseClosesIssues(intentMdPath) {
  let text;
  try { text = fs.readFileSync(intentMdPath, "utf8"); }
  catch { return []; }
  const lines = text.split(/\r?\n/);

  // Strict precedence: if `## Issues` heading exists, it is the SSOT —
  // even if empty. Empty `## Issues` means zero issues, NOT "consult legacy".
  const hasNewSection = lines.some((l) => /^## Issues\s*$/.test(l));
  if (hasNewSection) return collectEntries(lines, /^## Issues\s*$/);

  // Fallback only when `## Issues` heading is wholly absent.
  return collectEntries(lines, /^## closes_issues\s*$/);
}

module.exports = { parseClosesIssues, parseIssueToken, ISSUE_TOKEN_CLI_GUARD_RE };
