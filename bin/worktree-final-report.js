#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { parseClosesIssues } = require("../hooks/lib/parse-closes-issues");
const notesLib = require("../hooks/lib/worktree-notes-sections");
const schema = require("../hooks/lib/final-report-schema");

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

// legacyKey is undefined for new categories (no alias); only cc_restart has a legacy alias.
function categoryValue(newKey, legacyKey) {
  const v = safeEnv(newKey);
  if (v !== "(none)") return v;
  if (legacyKey === undefined) return "not_required";
  const legacy = safeEnv(legacyKey);
  if (legacy !== "(none)") {
    if (legacy === "yes") return "required";
    if (legacy === "no") return "not_required";
    return legacy;
  }
  return "not_required";
}

function extractSection(text, heading) {
  return notesLib.extractSection(text, heading);
}

const closedIssues = parseClosesIssues(intentPath);
const closedIssuesLine =
  closedIssues.length === 0
    ? "- (none)"
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

function getSectionLines(heading) {
  const raw = getSection(heading);
  if (raw === "(none)") return ["- (none)"];
  return raw.split("\n");
}

// Always-on Post-Merge Actions block (no AGENTS_CONFIG_DIR gate).
const ctx = {
  safeEnv,
  closedIssuesLine,
  buildPostMergeLines: () => {
    return schema.CATEGORIES.map((cat) => {
      const v = categoryValue(cat.newKey, cat.legacyKey);
      const reasonVal = safeEnv(cat.reasonKey);
      if (v === "required" && reasonVal !== "(none)") {
        return `- ${cat.label}: required (${reasonVal})`;
      }
      return `- ${cat.label}: ${v}`;
    });
  },
  bugsLines: getSectionLines("BugsFound"),
  relatedLines: getSectionLines("RelatedTasks"),
  nextLines: getSectionLines("NextTasks"),
};

const body = schema.renderCanonicalReport(envFileValues, sessionId, ctx);
process.stdout.write(body + "\n");
process.stdout.write("\n<<WORKFLOW_MARK_STEP_final_report_complete>>\n");
