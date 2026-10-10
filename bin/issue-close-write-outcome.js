#!/usr/bin/env node
// Write or update a per-issue entry in <CONTROL_DIR>/issue-close-outcome.json.
// Usage:
//   node issue-close-write-outcome.js <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>
//   node issue-close-write-outcome.js --session <sid> --empty
//   node issue-close-write-outcome.js --non-github|--wf-meta <issues-json-array> <outcome-file>
//   node issue-close-write-outcome.js --fallback <intent-md> <outcome-file>
// Normal mode and --empty resolve the outcome file through the control-dir resolver.
// Exit 0 on success or skip (session-id unresolvable); 1 on error (stderr).

"use strict";
const fs = require("fs");
const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..");
const OUTCOME_NAME = "issue-close-outcome.json";

function outcomePathFor(sessionId) {
  const { controlPath } = require(path.join(__dirname, "..", "hooks", "workflow-state", "state-io", "control-dir"));
  return controlPath(sessionId, OUTCOME_NAME, { forWrite: true });
}

function plansDirOrEmpty() {
  try { return require(path.join(__dirname, "..", "hooks", "lib", "workflow-plans-dir")).getWorkflowPlansDir(); } catch (_) { return ""; }
}

function resolveSessionId() {
  try {
    return require(path.join(__dirname, "..", "hooks", "workflow-state")).resolveSessionId() || "";
  } catch (_) {
    // session-id-ssot: waived (catch fallback) — reached only when the resolver above is unloadable
    const codeSid = process.env.CLAUDE_CODE_SESSION_ID;
    if (codeSid && /^[A-Za-z0-9_-]+$/.test(codeSid.trim())) return codeSid.trim();
    return "";
  }
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

// --session <sid> --empty: seed an empty bag (replaces the prompt's direct printf).
if (args[0] === "--session" && args[2] === "--empty") {
  const sid = args[1] || "";
  if (!/^[A-Za-z0-9_-]+$/.test(sid)) {
    process.stderr.write("issue-close-write-outcome: --session must match [A-Za-z0-9_-]+\n");
    process.exit(1);
  }
  try {
    fs.writeFileSync(outcomePathFor(sid), JSON.stringify({ issues: [] }, null, 2) + "\n");
  } catch (e) {
    process.stderr.write("issue-close-write-outcome: --empty write failed: " + e.message + "\n");
    process.exit(1);
  }
  process.exit(0);
}

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
  for (const entry of issues) {
    const issueNumber = typeof entry === "number" ? entry : entry.number;
    const issueRepo = (typeof entry === "object" && entry.repo) ? entry.repo : undefined;
    upsertEntry(bag, {
      issueNumber, issueRepo, state: "skipped-non-github",
      historyEntry: "skipped", issueClosed: "skipped",
      sentinelsPosted: "skipped", wipCleared: "skipped",
    });
  }
  fs.writeFileSync(outFile, JSON.stringify(bag, null, 2));
  process.exit(0);
}

// --wf-meta <issues-json-array> <outcome-file>
if (args[0] === "--wf-meta") {
  const issuesJson = args[1];
  const outFile = args[2];
  if (!issuesJson || !outFile) {
    process.stderr.write("issue-close-write-outcome: --wf-meta requires <issues-json> <outcome-file>\n");
    process.exit(1);
  }
  let issues;
  try { issues = JSON.parse(issuesJson); } catch (e) {
    process.stderr.write("issue-close-write-outcome: invalid JSON array: " + e.message + "\n");
    process.exit(1);
  }
  const bag = readBag(outFile);
  for (const entry of issues) {
    const issueNumber = typeof entry === "number" ? entry : entry.number;
    const issueRepo = (typeof entry === "object" && entry.repo) ? entry.repo : undefined;
    upsertEntry(bag, {
      issueNumber, issueRepo, state: "skipped_wf_meta",
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
    // #1644 stage 4: route through the write-once session cache. sessionId is
    // derived from the <sid>-intent.md filename convention (no --session-id
    // is passed to --fallback mode).
    const { getClosesIssues } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks/workflow-state/session-facts.js"));
    const fallbackSessionId = path.basename(intentMd, "-intent.md");
    issues = getClosesIssues(fallbackSessionId, { plansDir: path.dirname(intentMd) });
  } catch (e) {
    process.stderr.write("[issue-close-write-outcome] WARN: could not parse closes_issues: " + e.message + "\n");
  }
  const bag = readBag(outFile);
  for (const entry of issues) {
    const issueNumber = typeof entry === "number" ? entry : entry.number;
    const issueRepo = (typeof entry === "object" && entry.repo) ? entry.repo : undefined;
    upsertEntry(bag, {
      issueNumber, issueRepo, state: "failed",
      historyEntry: "failed", issueClosed: "failed",
      sentinelsPosted: "failed", wipCleared: "failed",
    });
  }
  fs.writeFileSync(outFile, JSON.stringify(bag, null, 2));
  process.exit(0);
}

// --session-id <id> --out-file <path> <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>
if (args[0] === "--session-id") {
  const sessionId = args[1];
  const outFile = args[3];
  if (!sessionId || args[2] !== "--out-file" || !outFile) {
    process.stderr.write(
      "Usage: issue-close-write-outcome.js --session-id <id> --out-file <path> <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>\n"
    );
    process.exit(1);
  }
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
    process.stderr.write("issue-close-write-outcome: session-id must match [A-Za-z0-9_-]+\n");
    process.exit(1);
  }
  const remaining = args.slice(4);
  const [issueArg2, state2, historyEntry2, issueClosed2, sentinelsPosted2, wipCleared2] = remaining;
  if (!issueArg2 || !state2 || !historyEntry2 || !issueClosed2 || !sentinelsPosted2 || !wipCleared2) {
    process.stderr.write(
      "Usage: issue-close-write-outcome.js --session-id <id> --out-file <path> <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>\n"
    );
    process.exit(1);
  }
  const issueNumber2 = parseInt(issueArg2, 10);
  if (isNaN(issueNumber2)) {
    process.stderr.write("issue-close-write-outcome: <N> must be an integer\n");
    process.exit(1);
  }
  const bag2 = readBag(outFile);
  upsertEntry(bag2, {
    issueNumber: issueNumber2,
    state: state2,
    historyEntry: historyEntry2,
    issueClosed: issueClosed2,
    sentinelsPosted: sentinelsPosted2,
    wipCleared: wipCleared2,
  });
  // Best-effort: ensure sibling issues in this session's closes_issues also get
  // an entry, marked "subsumed". A session may cover multiple issues; without
  // this, only the primary N gets written and siblings go missing.
  try {
    // #1644 stage 4: route through the write-once session cache.
    const { getClosesIssues } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks/workflow-state/session-facts.js"));
    const siblings = getClosesIssues(sessionId, { plansDir: plansDirOrEmpty() }) || [];
    for (const entry of siblings) {
      const siblingNumber = typeof entry === "number" ? entry : entry.number;
      if (siblingNumber === issueNumber2) continue;
      if (bag2.issues.some((e) => e && e.issueNumber === siblingNumber)) continue;
      upsertEntry(bag2, {
        issueNumber: siblingNumber,
        state: "subsumed",
        historyEntry: "subsumed",
        issueClosed: "subsumed",
        sentinelsPosted: "subsumed",
        wipCleared: "subsumed",
      });
    }
  } catch (_) {}
  fs.writeFileSync(outFile, JSON.stringify(bag2, null, 2));
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

const sessionId = resolveSessionId();
if (!sessionId) {
  process.stderr.write("[issue-close-write-outcome] WARN: session id unresolved — outcome JSON not written\n");
  process.exit(0);
}

try {
  const outFile = outcomePathFor(sessionId);
  const bag = readBag(outFile);
  upsertEntry(bag, { issueNumber, state, historyEntry, issueClosed, sentinelsPosted, wipCleared });
  fs.writeFileSync(outFile, JSON.stringify(bag, null, 2));
} catch (e) {
  process.stderr.write("[issue-close-finalize] WARN: outcome JSON write failed: " + e.message + "\n");
}
