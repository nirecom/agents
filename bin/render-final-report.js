#!/usr/bin/env node
// CLI wrapper for renderFinalReport: reads input files, renders the Final
// Report by substituting all placeholders, and writes the result to stdout.
//
// Usage: node render-final-report.js <session-id> <env-json-path> <outcome-json-path> <intent-md-path> [<supervisor-state-json-path>]
//
// Exit 0 on success; exit 1 on usage error, missing/invalid env JSON, or any
// error thrown by renderFinalReport.

"use strict";
const fs = require("fs");
const path = require("path");

const USAGE =
  "Usage: render-final-report.js <session-id> <env-json-path> <outcome-json-path> <intent-md-path> [<supervisor-state-json-path>]\n";

function fail(msg) {
  process.stderr.write(msg);
  process.exit(1);
}

const sessionId = process.argv[2];
if (!sessionId || !/^[A-Za-z0-9_-]+$/.test(sessionId)) {
  fail(USAGE);
}

const envPath = process.argv[3];
if (!envPath) fail(USAGE);

let env;
try {
  env = JSON.parse(fs.readFileSync(envPath, "utf8"));
} catch (err) {
  fail(`render-final-report: cannot read env JSON ${envPath}: ${err.message}\n`);
}

let outcome = { issues: [] };
const outcomePath = process.argv[4];
if (outcomePath) {
  if (!fs.existsSync(outcomePath)) {
    fail(`render-final-report: outcome JSON not found: ${outcomePath}\n`);
  }
  try {
    outcome = JSON.parse(fs.readFileSync(outcomePath, "utf8"));
  } catch (_) {
    outcome = { issues: [] };
  }
}

let closesIssues = [];
const intentPath = process.argv[5];
if (intentPath) {
  if (!fs.existsSync(intentPath)) {
    fail(`render-final-report: intent.md not found: ${intentPath}\n`);
  }
  const { parseClosesIssues } = require(path.resolve(__dirname, "../hooks/lib/parse-closes-issues"));
  closesIssues = parseClosesIssues(intentPath).map((e) => e.number);
}

const NOTES_SECTIONS = ["BugsFound", "RelatedTasks", "NextTasks"];
function extractNotesSections(notesPath) {
  const result = { BugsFound: "(none)", RelatedTasks: "(none)", NextTasks: "(none)" };
  let text;
  try {
    text = fs.readFileSync(notesPath, "utf8");
  } catch (_) {
    return result;
  }
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  let current = null;
  const buffers = { BugsFound: [], RelatedTasks: [], NextTasks: [] };
  for (const line of lines) {
    const headingMatch = line.match(/^## (.+?)\s*$/);
    if (headingMatch) {
      const name = headingMatch[1].trim();
      current = NOTES_SECTIONS.includes(name) ? name : null;
      continue;
    }
    if (current) buffers[current].push(line);
  }
  for (const name of NOTES_SECTIONS) {
    const content = buffers[name].join("\n").trim();
    result[name] = content || "(none)";
  }
  return result;
}

let notesSections = { bugs: "(none)", related: "(none)", next: "(none)" };
const notesBackupPath = env.NOTES_BACKUP_PATH;
if (notesBackupPath && fs.existsSync(notesBackupPath)) {
  const extracted = extractNotesSections(notesBackupPath);
  notesSections = { bugs: extracted.BugsFound, related: extracted.RelatedTasks, next: extracted.NextTasks };
}

let supervisorState = null;
const supervisorPath = process.argv[6];
if (supervisorPath && fs.existsSync(supervisorPath)) {
  try {
    supervisorState = JSON.parse(fs.readFileSync(supervisorPath, "utf8"));
  } catch (_) {
    supervisorState = null;
  }
}

try {
  const { renderFinalReport } = require(path.resolve(__dirname, "../hooks/lib/final-report-schema"));
  const result = renderFinalReport(sessionId, { env, outcome, closesIssues, notesSections, supervisorState });
  process.stdout.write(result);
} catch (err) {
  fail(`render-final-report: ${err.message}\n`);
}
