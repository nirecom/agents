"use strict";
// hooks/lib/plan-sync/lease-push.js
// The replacement push: local main overwrites origin's main only while origin's main is still
// the expected commit X (an explicit lease, never the remote-tracking ref's value).
const G = require("./git");

function pushMainWithLease(plansDir, expected, opts) {
  return G.runGit(plansDir, ["push", "--no-verify", "--porcelain", `--force-with-lease=${G.MAIN_REF}:${expected}`,
    "origin", `${G.MAIN_REF}:${G.MAIN_REF}`], G.transferOpts(opts));
}

// A remote-side refusal that says nothing about the remote's policy (a lock race, a moved ref).
const TRANSIENT_REMOTE_RE = /failed to lock|cannot lock|stale info/i;

// classifyLeasePush(r) -> "ok" | "timeout" | "lease-miss" | "remote-rejected" | "other"
// lease-miss: origin's main moved off the expected commit. remote-rejected: the remote refused
// the forced update itself (deny non-fast-forward, a protected branch, a declining hook).
function classifyLeasePush(r) {
  const res = r || {};
  if (res.status === 0) return "ok";
  if (res.timedOut) return "timeout";
  const text = `${res.stdout || ""}\n${res.stderr || ""}`;
  for (const line of text.split(/\r?\n/)) {
    if (/\[rejected\].*\(stale info\)/.test(line)) return "lease-miss";
  }
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/\[remote rejected\].*\((.*)\)\s*$/);
    if (m) return TRANSIENT_REMOTE_RE.test(m[1]) ? "other" : "remote-rejected";
  }
  return "other";
}

module.exports = { pushMainWithLease, classifyLeasePush };
