"use strict";
// Detects whether the current session is in the worktree-end cleanup phase by
// content-checking the session's final-report env JSON.
// existsSync alone does NOT distinguish worktree-end from ordinary session-close;
// a content-check on 2 fields (WORKTREE_PATH + MERGE_SHA presence) is required.
const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");

// The sid embedded in the env filename may be the wsid (workflow session ID),
// not the CC session ID; callers must try BOTH candidates.
function isWorktreeEndEnv(sessionId) {
  if (!sessionId || !/^[A-Za-z0-9_-]+$/.test(sessionId)) return false;
  let obj;
  try {
    const plansDir = getWorkflowPlansDir();
    const envPath = path.join(plansDir, sessionId + "-final-report-env.json");
    obj = JSON.parse(fs.readFileSync(envPath, "utf8"));
  } catch (_) {
    return false; // ENOENT / I/O / parse error — fail-open
  }
  return (
    typeof obj.WORKTREE_PATH === "string" &&
    obj.WORKTREE_PATH.length > 0 &&
    Object.prototype.hasOwnProperty.call(obj, "MERGE_SHA")
  );
}

module.exports = { isWorktreeEndEnv };
