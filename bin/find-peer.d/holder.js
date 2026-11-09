"use strict";
// The working session of an issue: the WIP holder that `wip-state.sh holder <N>` prints.

const path = require("path");
const { spawnSync } = require("child_process");

const SID_RE = /^[A-Za-z0-9_-]+$/;

// holderResult(readHolder, issue, repo) -> {sessionId} | {code, reason}. A read that throws, or a
// value that is not one session id, is forge-read-failed; the bad value is never echoed.
function holderResult(readHolder, issue, repo) {
  let raw;
  try {
    raw = readHolder(issue, repo);
  } catch (e) {
    return { code: 7, reason: "forge-read-failed" };
  }
  const id = String(raw === null || raw === undefined ? "" : raw).replace(/\r?\n$/, "");
  if (id === "") return { code: 3, reason: "no-holder" };
  if (!SID_RE.test(id)) return { code: 7, reason: "forge-read-failed" };
  return { sessionId: id };
}

// readHolderViaWipState(issue, repo) -> the holder id or "" (throws when the verb fails).
function readHolderViaWipState(issue, repo) {
  const { toWindowsPath } = require(path.join(__dirname, "..", "..", "hooks", "lib", "branch-diff"));
  const script = path.join(__dirname, "..", "github-issues", "wip-state.sh").replace(/\\/g, "/");
  const args = [script, "holder", String(issue)];
  if (repo) args.push("--repo", repo);
  const r = spawnSync("bash", args, { cwd: toWindowsPath(process.cwd()), encoding: "utf8", timeout: 60000, windowsHide: true });
  if (r.error || r.status !== 0) throw new Error(`wip-state.sh holder exited ${r.status}: ${String(r.stderr || "").trim()}`);
  return String(r.stdout || "");
}

module.exports = { holderResult, readHolderViaWipState };
