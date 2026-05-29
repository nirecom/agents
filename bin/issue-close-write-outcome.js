#!/usr/bin/env node
// Write or update a per-issue entry in <session-id>-issue-close-outcome.json.
//
// Usage:
//   node issue-close-write-outcome.js <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>
//   node issue-close-write-outcome.js --non-github <issues-json-array> <outcome-file>
//   node issue-close-write-outcome.js --fallback <intent-md> <outcome-file>
//
// Normal mode: resolves PLANS_DIR and SESSION_ID internally; reads CLAUDE_ENV_FILE.
// --non-github: writes skipped-non-github entries for all issues in the JSON array.
// --fallback: writes failed entries for all issues parsed from intent.md.
//
// Exit 0 on success or skip (session-id unresolvable).
// Exit 1 on unexpected error (prints to stderr).

"use strict";
const fs = require("fs");
const path = require("path");

const AGENTS_CONFIG_DIR = process.env.AGENTS_CONFIG_DIR;

function resolvePlansDir() {
  try {
    const { execSync } = require("child_process");
    return execSync(`bash "${AGENTS_CONFIG_DIR}/bin/workflow-plans-dir"`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (_) {
    return process.env.WORKFLOW_PLANS_DIR || path.join(require("os").homedir(), ".workflow-plans");
  }
}

function resolveSessionId() {
  try {
    const envFile = process.env.CLAUDE_ENV_FILE || "";
    if (envFile) {
      const e = JSON.parse(fs.readFileSync(envFile, "utf8"));
      if (e && e.CLAUDE_SESSION_ID) return e.CLAUDE_SESSION_ID;
    }
  } catch (_) {}
  return process.env.CLAUDE_SESSION_ID || "";
}

function readBag(p) {
  try {
    const parsed = JSON.parse(fs.readFileSync(p, "utf8"));
    if (parsed && Array.isArray(parsed.issues)) return parsed;
  } catch (_) {}
  return { issues: [] };
}

function upsertEntry(bag, entry) {
  bag.issues = bag.issues.filter((e) => e && e.issueNumber !== entry.issueNumber);
  bag.issues.push(entry);
}

const args = process.argv.slice(2);

// --non-github <issues-json-array> <outcome-file>
if (args[0] === "--non-github") {
  const issuesJson = args[1];
  const outFile = args[2];
  if (!issuesJson || !outFile) {
    process.stderr.write("issue-close-write-outcome: --non-github requires <issues-json> <outcome-file>\n");
    process.exit(1);
  }
  let issues;
  try { issues = JSON.parse(issuesJson); } catch (e) {
    process.stderr.write("issue-close-write-outcome: invalid JSON array: " + e.message + "\n");
    process.exit(1);
  }
  const bag = readBag(outFile);
  for (const n of issues) {
    upsertEntry(bag, {
      issueNumber: n, state: "skipped-non-github",
      historyEntry: "skipped", issueClosed: "skipped",
      sentinelsPosted: "skipped", wipCleared: "skipped",
    });
  }
  fs.writeFileSync(outFile, JSON.stringify(bag, null, 2));
  process.exit(0);
}

// --fallback <intent-md> <outcome-file>
if (args[0] === "--fallback") {
  const intentMd = args[1];
  const outFile = args[2];
  if (!intentMd || !outFile) {
    process.stderr.write("issue-close-write-outcome: --fallback requires <intent-md> <outcome-file>\n");
    process.exit(1);
  }
  let issues = [];
  try {
    const parseClosesIssues = require(path.join(AGENTS_CONFIG_DIR, "hooks/lib/parse-closes-issues.js"));
    issues = parseClosesIssues.parseClosesIssues(intentMd);
  } catch (e) {
    process.stderr.write("[issue-close-write-outcome] WARN: could not parse closes_issues: " + e.message + "\n");
  }
  const bag = readBag(outFile);
  for (const n of issues) {
    upsertEntry(bag, {
      issueNumber: n, state: "failed",
      historyEntry: "failed", issueClosed: "failed",
      sentinelsPosted: "failed", wipCleared: "failed",
    });
  }
  fs.writeFileSync(outFile, JSON.stringify(bag, null, 2));
  process.exit(0);
}

// Normal mode: <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>
const [issueArg, state, historyEntry, issueClosed, sentinelsPosted, wipCleared] = args;
if (!issueArg || !state || !historyEntry || !issueClosed || !sentinelsPosted || !wipCleared) {
  process.stderr.write(
    "Usage: issue-close-write-outcome.js <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>\n"
  );
  process.exit(1);
}
const issueNumber = parseInt(issueArg, 10);
if (isNaN(issueNumber)) {
  process.stderr.write("issue-close-write-outcome: <N> must be an integer\n");
  process.exit(1);
}

const plansDir = resolvePlansDir();
const sessionId = resolveSessionId();
if (!sessionId) {
  process.stderr.write("[issue-close-finalize] WARN: session id unresolved — outcome JSON not written\n");
  process.exit(0);
}

const outFile = path.join(plansDir, sessionId + "-issue-close-outcome.json");
const bag = readBag(outFile);
upsertEntry(bag, { issueNumber, state, historyEntry, issueClosed, sentinelsPosted, wipCleared });
try {
  fs.writeFileSync(outFile, JSON.stringify(bag, null, 2));
} catch (e) {
  process.stderr.write("[issue-close-finalize] WARN: outcome JSON write failed: " + e.message + "\n");
}
