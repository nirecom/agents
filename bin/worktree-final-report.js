#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { parseClosesIssues } = require("../hooks/lib/parse-closes-issues");

const [, , intentPath, notesPath, sessionId] = process.argv;

if (!intentPath || !sessionId) {
  process.stderr.write(
    "Usage: worktree-final-report.js <intent.md> <notes.md|''> <session-id>\n"
  );
  process.exit(1);
}

function hasTraversal(p) {
  return path.normalize(p).split(/[/\\]/).includes("..");
}

if (hasTraversal(intentPath)) {
  process.stderr.write("[worktree-final-report] path traversal in intent path\n");
  process.exit(1);
}
if (notesPath && hasTraversal(notesPath)) {
  process.stderr.write("[worktree-final-report] path traversal in notes path\n");
  process.exit(1);
}

function safeEnv(name) {
  const v = process.env[name];
  return v !== undefined && v !== "" ? v : "(none)";
}

function extractSection(text, heading) {
  const lines = text.split(/\r?\n/);
  let inSection = false;
  const bullets = [];
  for (const line of lines) {
    if (line === `## ${heading}`) { inSection = true; continue; }
    if (inSection && (line.startsWith("## ") || line.startsWith("### "))) break;
    if (inSection && line.startsWith("- ")) bullets.push(line);
  }
  if (bullets.length === 0) return "(none)";
  if (bullets.length === 1 && bullets[0] === "- (none)") return "(none)";
  return bullets.join("\n");
}

const closedIssues = parseClosesIssues(intentPath);
const closedIssuesLine =
  closedIssues.length === 0
    ? "(none)"
    : "- " + closedIssues.map((n) => `#${n}`).join(", ");

let notesText = null;
if (notesPath) {
  try {
    notesText = fs.readFileSync(notesPath, "utf8");
  } catch {
    process.stderr.write(
      `[worktree-final-report] notes file not found: ${notesPath}\n`
    );
  }
}

function getSection(heading) {
  if (!notesText) return "(none)";
  return extractSection(notesText, heading);
}

const report = [
  `## Final Report — ${sessionId}`,
  "",
  "### Closed Issues",
  closedIssuesLine,
  "",
  "### Merged PR",
  `- PR #${safeEnv("PR_NUMBER")}: ${safeEnv("PR_TITLE")}`,
  `- URL: ${safeEnv("PR_URL")}`,
  `- State: ${safeEnv("PR_STATE")}`,
  "",
  "### Worktree",
  `- Branch: ${safeEnv("BRANCH")}`,
  `- Path: ${safeEnv("WORKTREE_PATH")}`,
  `- Created: ${safeEnv("CREATED_DATE")}`,
  "- Removed: ✓",
  "",
  "### Backup",
  `- Manifest: ${safeEnv("BACKUP_MANIFEST_PATH")}`,
  `- Branches deleted: ${safeEnv("BRANCH_DELETED")}`,
  "",
  "### Bugs Found",
  getSection("BugsFound"),
  "",
  "### Related Tasks",
  getSection("RelatedTasks"),
  "",
  "### Next Tasks",
  getSection("NextTasks"),
  "",
].join("\n");

process.stdout.write(report);
