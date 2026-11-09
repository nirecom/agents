"use strict";
// find-peer: resolve the SendMessage destination of an issue's working (WIP holder) or origin
// session, or of a session id, and never guess (#2668; contract: docs/architecture/cross-session-messaging.md).
//   find-peer --issue <N> [--role working|origin] [--repo <slug>] [--agents-file <path>]
//   find-peer --session <sid|self> [--agents-file <path>]
// Prints ROLE / SESSION_ID / DESTINATION / DESTINATION_KIND, or REASON=<token> with exit
// 2 usage | 3 no-holder | 4 no-origin | 5 not-in-list | 6 ambiguous | 7 forge-read-failed | 8 agents-list-required.

const fs = require("fs");
const path = require("path");
const { parseAgentsList, resolveFromList } = require("./agents-list");
const { holderResult, readHolderViaWipState } = require("./holder");
const { originResult, readIssueBodyViaForge } = require("./origin");

const SID_RE = /^[A-Za-z0-9_-]+$/;
const ISSUE_RE = /^[1-9][0-9]*$/;
const REPO_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]*(\/[A-Za-z0-9][A-Za-z0-9_.-]*)*$/;
const KINDS = ["session-id", "ref", "name"];
const FLAGS = new Set(["--issue", "--role", "--repo", "--agents-file", "--session"]);

const failure = (code, reason) => ({ code, stdout: `REASON=${reason}\n` });

// parseArgs(argv) -> {o} | {usage: reason}. Each flag takes the next element as its value.
function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    if (!FLAGS.has(flag)) return { usage: "unknown-argument" };
    if (i + 1 >= argv.length) return { usage: "missing-value" };
    if (o[flag] !== undefined) return { usage: "repeated-argument" };
    o[flag] = argv[i + 1];
  }
  const issue = o["--issue"];
  const session = o["--session"];
  if ((issue === undefined) === (session === undefined)) return { usage: "need-issue-or-session" };
  if (issue !== undefined && !ISSUE_RE.test(issue)) return { usage: "bad-issue" };
  if (session !== undefined && session !== "self" && !SID_RE.test(session)) return { usage: "bad-session" };
  if (session !== undefined && (o["--role"] !== undefined || o["--repo"] !== undefined)) return { usage: "issue-only-flag" };
  const role = o["--role"] === undefined ? "working" : o["--role"];
  if (!["working", "origin"].includes(role)) return { usage: "bad-role" };
  if (o["--repo"] !== undefined && !REPO_RE.test(o["--repo"])) return { usage: "bad-repo" };
  if (o["--agents-file"] === "") return { usage: "bad-agents-file" };
  return { o: { issue, session, role, repo: o["--repo"] || "", agentsFile: o["--agents-file"] } };
}

// readList(file) -> {entries} | failure; the list is read only when the policy needs it.
function readList(file) {
  if (file === undefined) return failure(8, "agents-list-required");
  let text;
  try {
    const { toWindowsPath } = require(path.join(__dirname, "..", "..", "hooks", "lib", "branch-diff"));
    text = fs.readFileSync(toWindowsPath(file), "utf8");
  } catch (e) {
    return failure(2, "agents-file-unreadable");
  }
  const entries = parseAgentsList(text);
  return entries ? { entries } : failure(2, "agents-list-unparsable");
}

function run(argv, deps) {
  const d = deps || {};
  const kind = d.policy || require("./destination-policy").DESTINATION_KIND;
  if (!KINDS.includes(kind)) return failure(2, "bad-destination-policy");
  const parsed = parseArgs(argv);
  if (parsed.usage) return failure(2, parsed.usage);
  const o = parsed.o;
  // A list the policy needs is checked before any forge read, so a missing one fails fast.
  const list = kind === "session-id" ? null : readList(o.agentsFile);
  if (list && list.code !== undefined) return list;

  let role;
  let found;
  if (o.session !== undefined) {
    role = o.session === "self" ? "self" : "session";
    found = o.session === "self" ? selfResult(d.resolveSelf || resolveSelfViaWorkflowState) : { sessionId: o.session };
  } else if (o.role === "origin") {
    role = "origin";
    found = originResult(d.readIssueBody || readIssueBodyViaForge, o.issue, o.repo);
  } else {
    role = "working";
    found = holderResult(d.readHolder || readHolderViaWipState, o.issue, o.repo);
  }
  if (found.code !== undefined) return failure(found.code, found.reason);

  const sid = found.sessionId;
  const dest = list ? resolveFromList(list.entries, kind, sid) : { destination: sid };
  if (dest.code !== undefined) return failure(dest.code, dest.reason);
  return { code: 0, stdout: `ROLE=${role}\nSESSION_ID=${sid}\nDESTINATION=${dest.destination}\nDESTINATION_KIND=${kind}\n` };
}

// selfResult(resolveSelf) -> {sessionId} | usage failure: no session to speak for is a caller error.
function selfResult(resolveSelf) {
  let id;
  try {
    id = resolveSelf();
  } catch (e) {
    id = null;
  }
  return typeof id === "string" && SID_RE.test(id) ? { sessionId: id } : { code: 2, reason: "session-unresolvable" };
}

function resolveSelfViaWorkflowState() {
  return require(path.join(__dirname, "..", "..", "hooks", "workflow-state")).resolveSessionId();
}

function cli() {
  const r = run(process.argv.slice(2));
  process.stdout.write(r.stdout);
  process.exitCode = r.code;
}

module.exports = { run, cli, parseArgs };
