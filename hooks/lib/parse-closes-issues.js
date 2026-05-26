"use strict";

// Single source of truth for ## Issues parsing (new SSOT per #548).
// Falls back to legacy ## closes_issues only when ## Issues heading is wholly absent.
// Code-level consumers (require this module):
//   - bin/worktree-final-report.js
//   - bin/parse-closes-issues (CLI wrapper)
// Prose/prompt references (pointer comments only — no require):
//   - skills/commit-push, issue-close-stage, issue-close-finalize

const fs = require("fs");

function collectNums(lines, headingRe) {
  let inSection = false;
  const nums = [];
  for (const line of lines) {
    if (headingRe.test(line)) {
      inSection = true;
      continue;
    }
    if (inSection && /^## /.test(line)) break;
    if (inSection) {
      // Accept: "- 123", "- #123", "- #123: <title>", "- #123: title with: colons"
      const m = line.match(/^-\s+#?(\d+)(?::.*)?\s*$/);
      if (m) nums.push(Number(m[1]));
    }
  }
  return nums;
}

function parseClosesIssues(intentMdPath) {
  let text;
  try { text = fs.readFileSync(intentMdPath, "utf8"); }
  catch { return []; }
  const lines = text.split(/\r?\n/);

  // Strict precedence: if `## Issues` heading exists, it is the SSOT —
  // even if empty. Empty `## Issues` means zero issues, NOT "consult legacy".
  const hasNewSection = lines.some((l) => /^## Issues\s*$/.test(l));
  if (hasNewSection) return collectNums(lines, /^## Issues\s*$/);

  // Fallback only when `## Issues` heading is wholly absent.
  return collectNums(lines, /^## closes_issues\s*$/);
}

module.exports = { parseClosesIssues };
