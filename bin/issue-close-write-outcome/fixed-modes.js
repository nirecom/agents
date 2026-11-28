"use strict";
// --empty / --non-github / --wf-meta / --fallback of bin/issue-close-write-outcome.js: every entry of
// a mode carries one fixed state. They match by the bag's existing homeRepo and never rewrite it.
// --empty never erases recorded entries: a bag holding any is kept as is.

const fs = require("fs");
const path = require("path");
const B = require("./bag");

const fail = (msg) => {
  process.stderr.write(`issue-close-write-outcome: ${msg}\n`);
  return 1;
};

function runEmpty(sid) {
  if (!/^[A-Za-z0-9_-]+$/.test(sid || "")) return fail("--session must match [A-Za-z0-9_-]+");
  try {
    const outFile = B.outcomePathFor(sid);
    const kept = B.readBag(outFile).issues.length;
    if (kept > 0) {
      process.stderr.write(`issue-close-write-outcome: --empty kept ${kept} recorded outcome entries\n`);
      return 0;
    }
    fs.writeFileSync(outFile, JSON.stringify({ issues: [] }, null, 2) + "\n");
  } catch (e) {
    return fail("--empty write failed: " + e.message);
  }
  return 0;
}

function writeFixed(outFile, issues, state, detail) {
  const bag = B.readBag(outFile);
  const home = B.bagHome(bag);
  for (const entry of issues) {
    const issueNumber = typeof entry === "number" ? entry : entry.number;
    const issueRepo = (typeof entry === "object" && entry.repo) ? entry.repo : undefined;
    B.upsertEntry(bag, {
      issueNumber, issueRepo, state,
      historyEntry: detail, issueClosed: detail, sentinelsPosted: detail, wipCleared: detail,
    }, home);
  }
  B.writeBag(outFile, bag);
  return 0;
}

const LIST_STATES = { "--non-github": "skipped-non-github", "--wf-meta": "skipped_wf_meta" };

function runList(mode, issuesJson, outFile) {
  if (!issuesJson || !outFile) return fail(`${mode} requires <issues-json> <outcome-file>`);
  let issues;
  try { issues = JSON.parse(issuesJson); } catch (e) {
    return fail("invalid JSON array: " + e.message);
  }
  return writeFixed(outFile, issues, LIST_STATES[mode], "skipped");
}

function runFallback(intentMd, outFile) {
  if (!intentMd || !outFile) return fail("--fallback requires <intent-md> <outcome-file>");
  let issues = [];
  try {
    // sessionId is derived from the <sid>-intent.md filename (--fallback has no --session-id).
    issues = B.getClosesIssues(path.basename(intentMd, "-intent.md"), path.dirname(intentMd));
  } catch (e) {
    process.stderr.write("[issue-close-write-outcome] WARN: could not parse closes_issues: " + e.message + "\n");
  }
  return writeFixed(outFile, issues, "failed", "failed");
}

module.exports = { runEmpty, runList, runFallback, LIST_STATES };
