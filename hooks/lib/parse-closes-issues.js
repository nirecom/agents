"use strict";

// Single source of truth for ## Issues parsing (new SSOT per #548).
// Falls back to legacy ## closes_issues only when ## Issues heading is wholly absent.
// Code-level consumers (require this module):
//   - bin/parse-closes-issues (CLI wrapper)
// Prose/prompt references (pointer comments only — no require):
//   - skills/commit-push, issue-close-stage, issue-close-finalize
//
// Return type: Array<{number: number, repo?: string}>
//   - Local issue:      { number: 42 }           (no repo field)
//   - Short cross-repo: { number: 42, repo: "dotfiles-private" }
//   - Full cross-repo:  { number: 42, repo: "nirecom/dotfiles-private" }
// Normalization is lazy — stored as-received; full owner/repo is resolved at
// call site via `gh repo view` when needed.

const fs = require("fs");

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
      // Regex breakdown:
      //   (?:([a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)?)#|#)?
      //     Either "repo#" (with group 1 capture) or bare "#", or nothing (bare number)
      //   (\d+)  — group 2: issue number
      const m = line.match(/^-\s+(?:([a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)?)#|#)?(\d+)(?::.*)?\s*$/);
      if (m) {
        const entry = { number: Number(m[2]) };
        if (m[1]) entry.repo = m[1];
        entries.push(entry);
      }
    }
  }
  return entries;
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

module.exports = { parseClosesIssues };
