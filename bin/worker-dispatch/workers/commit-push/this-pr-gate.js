"use strict";
// bin/worker-dispatch/workers/commit-push/this-pr-gate.js
//
// #3145 S7: the push and the PR wait while WORKTREE_NOTES.md at payload.worktree_path (checked
// against the checked-out branch in Step 0) holds an unsettled this-pr finding. The commit itself
// still lands locally. Fail-closed: an unusable worktree_path or unreadable notes also hold.
// Git (the fixed-entry verification) runs only through gate.js runGit, i.e. spawn.js.

const fs = require("fs");
const path = require("path");
const { runGit } = require("./gate");
const { readOpenThisPr, formatOpenThisPrRefusal, formatDegradedRefusal } = require("../../../lib/this-pr-open");

const STATUS = "this_pr_open";

const FIRST_LINE = {
  push: (b) => `${b} not pushed; push and PR creation withheld (the commit stays local).`,
  pr: (b) => `${b} has no unpushed commits; PR creation withheld. If this branch already has a PR, it already carries every commit.`,
};

function isDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch (_e) { return false; }
}

// phase: "push" (before Step 5) | "pr" (resume with count = 0). -> null | { status, summary }
function thisPrGate(payload, ctx, log, phase) {
  const head = (FIRST_LINE[phase] || FIRST_LINE.push)(payload.branch);
  const wt = String(payload.worktree_path || "");
  if (wt === "" || !isDir(wt)) {
    return { status: STATUS, summary: `${head}\n${formatDegradedRefusal(`worktree_path is not a directory: ${wt || "(empty)"}`)}` };
  }
  const notes = path.join(wt, "WORKTREE_NOTES.md");
  const r = readOpenThisPr(notes, { runGit: (args) => runGit(ctx, payload, args, log) });
  if (r.state === "error") return { status: STATUS, summary: `${head}\n${formatDegradedRefusal(r.reason)}` };
  if (r.open.length === 0) return null;
  log.push(`this-pr gate: ${r.open.length} unsettled finding(s) — ${phase} withheld`);
  return { status: STATUS, summary: `${head}\n${formatOpenThisPrRefusal(notes, r.open)}` };
}

module.exports = { thisPrGate, THIS_PR_OPEN_STATUS: STATUS };
