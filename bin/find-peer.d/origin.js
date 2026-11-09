"use strict";
// The origin session of an issue: the "<!-- origin-session: <sid> -->" marker that
// bin/github-issues/lib/origin-session.sh appends to the issue body.

const path = require("path");

const MARKER_RE = /^<!-- origin-session: ([A-Za-z0-9_-]+) -->\r?$/gm;

// originResult(readIssueBody, issue, repo) -> {sessionId} | {code, reason}.
function originResult(readIssueBody, issue, repo) {
  let body;
  try {
    body = readIssueBody(issue, repo);
  } catch (e) {
    return { code: 7, reason: "forge-read-failed" };
  }
  if (typeof body !== "string") return { code: 7, reason: "forge-read-failed" };
  const ids = new Set([...body.matchAll(MARKER_RE)].map((m) => m[1]));
  if (ids.size === 0) return { code: 4, reason: "no-origin" };
  if (ids.size > 1) return { code: 6, reason: "ambiguous" };
  return { sessionId: [...ids][0] };
}

// readIssueBodyViaForge(issue, repo) -> the body through the origin's tracker (throws on failure).
function readIssueBodyViaForge(issue, repo) {
  const hooks = path.join(__dirname, "..", "..", "hooks");
  const { toWindowsPath } = require(path.join(hooks, "lib", "branch-diff"));
  const { originUrl } = require(path.join(hooks, "workflow-gate", "gh-detect"));
  const fr = require(path.join(hooks, "lib", "forge-router"));
  const cwd = toWindowsPath(process.cwd());
  const url = originUrl(cwd, { timeoutMs: 5000 });
  if (!url) throw new Error("no origin remote");
  const { type } = fr.resolveCodehostDescriptor(url, cwd);
  const tracker = fr.resolveTrackerDescriptor({ FORGE_TRACKER: fr.readTrackerConfig(cwd) }, type);
  const ref = { number: Number(issue) };
  if (repo) ref.repo = repo;
  const body = tracker.issueBody(url, ref, { timeoutMs: 15000, projectRoot: cwd });
  if (typeof body !== "string") throw new Error("the issue body could not be read");
  return body;
}

module.exports = { originResult, readIssueBodyViaForge };
