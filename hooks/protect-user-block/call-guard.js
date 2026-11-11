"use strict";
// One operation descriptor -> one bin/user-block-guard run -> { decision, reason }.
// rc 0 allow (no decision), 1 deny, 2 ask; usage, unknown rc, a timeout or too little time left deny.
const childProcess = require("child_process");
const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { remainingDecisionMs } = require("../lib/decision-time-limit");

const CLI = path.join(__dirname, "..", "..", "bin", "user-block-guard");
const SPAWN_MARGIN_MS = 500;
const CLI_MARGIN_MS = 1000;
const HOOK = "protect-user-block";

function argsOf(d) {
  const a = ["--op", d.op];
  if (d.issue) a.push("--issue", d.issue);
  if (d.repo) a.push("--repo", d.repo);
  if (d.nodeId) a.push("--node-id", d.nodeId);
  if (d.commentId) a.push("--comment-id", d.commentId);
  if (d.lastOwn) a.push("--last-own-comment");
  if (d.createIfNone) a.push("--create-if-none");
  if (d.title) {
    if (d.title.unreadable) a.push("--title-unreadable");
    else a.push("--new-title", d.title.value);
  }
  let input;
  if (d.body) {
    if (d.body.unreadable) a.push("--body-unreadable");
    else { a.push("--new-body-file", "-"); input = d.body.value; }
  }
  return { args: a, input };
}

function callGuard(d, cwd) {
  const remaining = remainingDecisionMs();
  const timeout = Math.floor((Number.isFinite(remaining) ? remaining : 10000) - SPAWN_MARGIN_MS);
  const deadline = timeout - CLI_MARGIN_MS;
  if (deadline <= 0) {
    return { decision: "deny", reason: `${HOOK}: too little decision time left to check the <user> block of this ${d.op}` };
  }
  const { args, input } = argsOf(d);
  args.push("--deadline-ms", String(deadline));
  const opts = { input: input === undefined ? "" : input, encoding: "utf8", timeout, windowsHide: true };
  const dir = normalizeCwd(cwd);
  if (dir) opts.cwd = dir;
  let res;
  try {
    res = childProcess.spawnSync(process.execPath, [CLI, ...args], opts);
  } catch (e) {
    return { decision: "deny", reason: `${HOOK}: bin/user-block-guard could not start (${e.message})` };
  }
  const line = String(res.stdout || "").split(/\r?\n/).find((l) => l.trim() !== "") || "";
  if (res.error || res.status === null) {
    return { decision: "deny", reason: `${HOOK}: bin/user-block-guard did not finish (${res.error ? res.error.code || res.error.message : res.signal})` };
  }
  if (res.status === 0) return { decision: "none", reason: "" };
  if (res.status === 1) return { decision: "deny", reason: line || `${HOOK}: denied by bin/user-block-guard` };
  if (res.status === 2) return { decision: "ask", reason: line || `${HOOK}: bin/user-block-guard asks for confirmation` };
  return { decision: "deny", reason: `${HOOK}: bin/user-block-guard exited ${res.status}${line ? ": " + line : ""}` };
}

module.exports = { callGuard, argsOf };
