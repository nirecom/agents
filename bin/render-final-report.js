#!/usr/bin/env node
// CLI wrapper for renderFinalReport: renders the Final Report to stdout.
// Usage: node render-final-report.js --session <session-id>
//   env / outcome / supervisor-state come from <CLAUDE_WORKFLOW_DIR>/<sid>.control/;
//   intent.md (an artifact) from <PLANS_DIR>/<sid>-intent.md.
// Legacy: <session-id> <env-json> <outcome-json> <intent-md> [<supervisor-state-json>] —
//   each control path is accepted only as the derived path or its <sid>-<name> basename.
// Exit 0 on success; 1 on usage error, rejected path, missing/invalid env JSON, or render error.

"use strict";
const fs = require("fs");
const path = require("path");

const { resolveControlFile } = require(path.join(__dirname, "lib", "session-control-file"));

const USAGE =
  "Usage: render-final-report.js --session <session-id>\n" +
  "       render-final-report.js <session-id> <env-json-path> <outcome-json-path> <intent-md-path> [<supervisor-state-json-path>]\n";

function fail(msg) {
  process.stderr.write(msg);
  process.exit(1);
}

function controlFile(sid, legacy, name) {
  try {
    return resolveControlFile({ sid, legacy, name, forWrite: false });
  } catch (err) {
    return fail(`render-final-report: ${err.message}\n`);
  }
}

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch (_) { return null; }
}

function parseInvocation(argv) {
  if (argv[0] === "--session") {
    if (argv.length !== 2) fail(USAGE);
    const { getWorkflowPlansDir } = require(path.resolve(__dirname, "../hooks/lib/workflow-plans-dir"));
    return { sessionId: argv[1], sessionForm: true, plansDir: getWorkflowPlansDir() };
  }
  const [sessionId, envArg, outcomeArg, intentArg, supervisorArg] = argv;
  if (!envArg) fail(USAGE);
  return { sessionId, envArg, outcomeArg, intentArg, supervisorArg, sessionForm: false };
}

const inv = parseInvocation(process.argv.slice(2));
const sessionId = inv.sessionId;
if (!sessionId || !/^[A-Za-z0-9_-]+$/.test(sessionId)) {
  fail(USAGE);
}

const envPath = controlFile(sessionId, inv.envArg, "final-report-env.json");
let env;
try {
  env = JSON.parse(fs.readFileSync(envPath, "utf8"));
} catch (err) {
  fail(`render-final-report: cannot read env JSON ${envPath}: ${err.message}\n`);
}

let outcome = { issues: [] };
if (inv.sessionForm || inv.outcomeArg) {
  const outcomePath = controlFile(sessionId, inv.outcomeArg, "issue-close-outcome.json");
  if (fs.existsSync(outcomePath)) {
    outcome = readJson(outcomePath) || { issues: [] };
  } else if (!inv.sessionForm) {
    fail(`render-final-report: outcome JSON not found: ${outcomePath}\n`);
  }
}

// #1644 stage 4: route through the write-once session cache instead of
// re-parsing intent.md on every render — a session that already recorded
// closes_issues returns it as-is.
let closesIssues = [];
let intentPlansDir = inv.sessionForm ? inv.plansDir : null;
if (inv.intentArg) {
  if (!fs.existsSync(inv.intentArg)) {
    fail(`render-final-report: intent.md not found: ${inv.intentArg}\n`);
  }
  intentPlansDir = path.dirname(inv.intentArg);
}
if (intentPlansDir !== null) {
  const { getClosesIssues } = require(path.resolve(__dirname, "../hooks/workflow-state/session-facts.js"));
  closesIssues = getClosesIssues(sessionId, { plansDir: intentPlansDir }).map((e) => e.number);
}

// Fail-open: an unreadable or absent notes backup yields the "(none)" triple
// rather than blocking the report.
let notesSections = { bugs: "(none)", related: "(none)", next: "(none)" };
const notesBackupPath = env.NOTES_BACKUP_PATH;
if (notesBackupPath && fs.existsSync(notesBackupPath)) {
  try {
    const notesText = fs.readFileSync(notesBackupPath, "utf8");
    const { compressNotesSections } = require(path.resolve(__dirname, "./render-final-report/notes"));
    const compressed = compressNotesSections(notesText, { backupPath: notesBackupPath });
    notesSections = { bugs: compressed.BugsFound, related: compressed.RelatedTasks, next: compressed.NextTasks };
  } catch (_) {
    notesSections = { bugs: "(none)", related: "(none)", next: "(none)" };
  }
}

let supervisorState = null;
if (inv.sessionForm || inv.supervisorArg) {
  const supervisorPath = controlFile(sessionId, inv.supervisorArg, "supervisor-state.json");
  if (fs.existsSync(supervisorPath)) supervisorState = readJson(supervisorPath);
}

try {
  const { renderFinalReport } = require(path.resolve(__dirname, "../hooks/lib/final-report-schema"));
  const result = renderFinalReport(sessionId, { env, outcome, closesIssues, notesSections, supervisorState });
  process.stdout.write(result);
} catch (err) {
  fail(`render-final-report: ${err.message}\n`);
}
