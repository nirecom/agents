#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { parseClosesIssues } = require("../hooks/lib/parse-closes-issues");
const notesLib = require("../hooks/lib/worktree-notes-sections");

// --- argv parsing: strip "--" separators, extract --env-file, keep positionals ---
const rawArgs = process.argv.slice(2).filter((a) => a !== "--");
let envFilePath = null;
let envFileExplicit = false;
const positionals = [];
{
  let i = 0;
  while (i < rawArgs.length) {
    if (rawArgs[i] === "--env-file" && i + 1 < rawArgs.length) {
      envFilePath = rawArgs[i + 1];
      envFileExplicit = true;
      i += 2;
    } else {
      positionals.push(rawArgs[i]);
      i++;
    }
  }
}

const intentPath = positionals[0];
const notesPath = positionals[1];
const sessionId = positionals[2];

if (!intentPath || !sessionId) {
  process.stderr.write(
    "Usage: worktree-final-report.js <intent.md> <notes.md|''> <session-id> [--env-file <path>]\n"
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

// --- env-file validation + load (must happen before any safeEnv call) ---
function isAbsolutePath(p) {
  if (typeof p !== "string" || p.length === 0) return false;
  if (p.startsWith("/")) return true;
  // Windows: letter + ':' followed by '/' or '\'
  if (/^[A-Za-z]:[\\/]/.test(p)) return true;
  return false;
}

let envFileValues = {};
if (envFileExplicit) {
  if (!isAbsolutePath(envFilePath) || hasTraversal(envFilePath)) {
    process.stderr.write(
      "[worktree-final-report] FATAL: --env-file path invalid (must be absolute, no .. segments): " +
        envFilePath + "\n"
    );
    process.exit(1);
  }
  try {
    const raw = fs.readFileSync(envFilePath, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("env-file JSON must be a plain object");
    }
    envFileValues = parsed;
  } catch (e) {
    process.stderr.write(
      "[worktree-final-report] FATAL: --env-file requested but unreadable: " +
        envFilePath + " (" + e.message + ")\n"
    );
    process.exit(1);
  }
}

function safeEnv(name) {
  const fromFile = envFileValues[name];
  if (fromFile !== undefined && fromFile !== "") return fromFile;
  const fromEnv = process.env[name];
  if (fromEnv !== undefined && fromEnv !== "") return fromEnv;
  return "(none)";
}

function extractSection(text, heading) {
  return notesLib.extractSection(text, heading);
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

const sections = [
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
];

// Agents-repo-only section: display whether Claude Code restart is needed.
// Use process.env directly (not safeEnv) for the gate: safeEnv returns "(none)"
// when unset, which is always truthy and would defeat the gate.
if (process.env.AGENTS_CONFIG_DIR) {
  sections.push(
    "### Claude Code Restart Required",
    `- ${safeEnv("CLAUDE_CODE_RESTART_REQUIRED")}`,
    "",
  );
}

sections.push(
  "### Bugs Found",
  getSection("BugsFound"),
  "",
  "### Related Tasks",
  getSection("RelatedTasks"),
  "",
  "### Next Tasks",
  getSection("NextTasks"),
  "",
);

const report = sections.join("\n");
process.stdout.write(report);
process.stdout.write("\n<<WORKFLOW_MARK_STEP_final_report_complete>>\n");
