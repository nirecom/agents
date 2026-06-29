"use strict";

// Single source of truth for intent.md `## worktrees` parsing (#1102).
// Mirrors hooks/lib/parse-closes-issues.js: a pure parser that reads the
// section and returns structured entries. Validation (repo whitelist, shell
// metachar, traversal, newline) lives downstream in hooks/lib/worktree-notes.js
// `validateSiblings` — this module only parses.
//
// Code-level consumers (require this module):
//   - bin/parse-worktrees (CLI wrapper)
// Prose/prompt references (pointer comments only — no require):
//   - agents/worktree-copy-worker.md Step 3b
//
// Schema (written by skills/clarify-intent CI-4): a `## worktrees` section
// where each entry is a `- repo: <owner/repo>` line immediately followed by a
// `  worktree_path: <absolute path>` line (2-space indent).
//
// Return type: Array<{repo: string, worktree_path: string}>
//   Order: source order. Entries with an empty repo or worktree_path are
//   dropped. Normalization is lazy — values are returned as-read.

const fs = require("fs");

function parseWorktrees(intentMdPath) {
  let text;
  try { text = fs.readFileSync(intentMdPath, "utf8"); }
  catch { return []; }
  const lines = text.split(/\r?\n/);

  const entries = [];
  let inSection = false;
  let pendingRepo = null;
  for (const line of lines) {
    if (/^## worktrees\s*$/.test(line)) {
      inSection = true;
      continue;
    }
    if (inSection && /^## /.test(line)) break;
    if (!inSection) continue;

    const repoMatch = line.match(/^-\s+repo:\s*(.+?)\s*$/);
    if (repoMatch) {
      pendingRepo = repoMatch[1];
      continue;
    }
    const pathMatch = line.match(/^\s+worktree_path:\s*(.+?)\s*$/);
    if (pathMatch && pendingRepo) {
      const repo = pendingRepo;
      const worktree_path = pathMatch[1];
      if (repo && worktree_path) entries.push({ repo, worktree_path });
      pendingRepo = null;
    }
  }
  return entries;
}

module.exports = { parseWorktrees };
