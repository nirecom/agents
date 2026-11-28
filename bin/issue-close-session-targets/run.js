"use strict";
// bin/issue-close-session-targets.js — the session's closes_issues, once per (repo, N) key, split by
// gh state into {closed, open, unknown} label lists (#3043 D2). Labels follow outcomeLabel.

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const USAGE = "Usage: issue-close-session-targets.js --session <sid> [--owner-repo <owner/repo>]\n";

function parseArgs(argv) {
  const out = { session: "", ownerRepo: "" };
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === "--session") out.session = argv[i + 1] || "";
    else if (argv[i] === "--owner-repo") out.ownerRepo = argv[i + 1] || "";
    else return null;
  }
  return out;
}

function main(argv) {
  const args = parseArgs(argv);
  if (!args || !/^[A-Za-z0-9_-]+$/.test(args.session)) {
    process.stderr.write(USAGE);
    return 1;
  }
  const { normalizeHome, refKey, refDisplay } = require(path.join(ROOT, "hooks", "lib", "issue-identity"));
  const { issueState } = require(path.join(ROOT, "bin", "lib", "issue-state"));
  const { getClosesIssues } = require(path.join(ROOT, "hooks", "workflow-state", "session-facts.js"));
  const { getWorkflowPlansDir } = require(path.join(ROOT, "hooks", "lib", "workflow-plans-dir"));
  const { resolvePlanArtifactOwner } = require(path.join(ROOT, "hooks", "workflow-state", "plan-artifact-owner.js"));
  const home = normalizeHome(args.ownerRepo);
  let refs;
  try {
    const plansDir = getWorkflowPlansDir();
    const intent = resolvePlanArtifactOwner(args.session, "intent", undefined, { plansDir });
    // parseClosesIssues reads an unreadable intent as [], which would pass for "no issues".
    if (intent.exists) fs.readFileSync(intent.path, "utf8");
    refs = getClosesIssues(args.session, { plansDir }) || [];
  } catch (e) {
    process.stderr.write(`issue-close-session-targets: could not read closes_issues: ${e.message}\n`);
    return 1;
  }
  const seen = new Set();
  const result = { closed: [], open: [], unknown: [] };
  for (const ref of refs) {
    if (!ref || !Number.isInteger(Number(ref.number))) continue;
    const key = refKey(ref, home);
    if (seen.has(key)) continue;
    seen.add(key);
    const state = issueState(ref, home);
    const bucket = state === "CLOSED" ? "closed" : state === "OPEN" ? "open" : "unknown";
    result[bucket].push(refDisplay(ref, home));
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return 0;
}

module.exports = { main, parseArgs };
