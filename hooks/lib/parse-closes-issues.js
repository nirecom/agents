"use strict";

// Single source of truth for ## closes_issues parsing.
// Code-level consumers (require this module):
//   - bin/worktree-final-report.js
// Prose/prompt references (pointer comments only — no require):
//   - skills/commit-push, issue-close-stage, issue-close-finalize

const fs = require("fs");

function parseClosesIssues(intentMdPath) {
  let text;
  try { text = fs.readFileSync(intentMdPath, "utf8"); }
  catch { return []; }
  const lines = text.split(/\r?\n/);
  let inSection = false;
  const nums = [];
  for (const line of lines) {
    if (/^## closes_issues\s*$/.test(line)) { inSection = true; continue; }
    if (inSection && /^## /.test(line)) break;
    if (inSection) {
      const m = line.match(/^- (\d+)\s*$/);
      if (m) nums.push(Number(m[1]));
    }
  }
  return nums;
}

module.exports = { parseClosesIssues };
