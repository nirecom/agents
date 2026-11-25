"use strict";
// The write_code completion check (#3145 S3/S4): a declared write_code completion is refused while
// a this-pr finding in the session's WORKTREE_NOTES.md is unsettled, and when the notes cannot be
// checked (unreadable, repo unresolved, cwd is not the session worktree). Absent notes pass.
// Read-only. The notes path comes from the trusted repo dir (process cwd), never from tool input.

const KINDS = Object.freeze({ open: "this-pr-open", degraded: "this-pr-open-degraded" });
// The judged gates; reset (the user's emergency reset) and recorded-verdict are not (S4).
const THIS_PR_GATES = Object.freeze(["sentinel", "advance", "mark"]);

// Lazy: bin/lib/this-pr-open.js reaches workflow-state, which this module's caller is part of.
function lib() {
  return require("../../../bin/lib/this-pr-open");
}

// -> null | { message, kind }
function checkWriteCodeThisPr(sessionId) {
  let m;
  try {
    m = lib();
  } catch (e) {
    return { kind: KINDS.degraded, message: `this-pr findings cannot be checked: ${(e && e.message) || e}` };
  }
  let res;
  try {
    res = m.resolveSessionNotesPath(sessionId);
  } catch (e) {
    res = { error: `notes path unresolved: ${(e && e.message) || e}` };
  }
  if (res.error) return { kind: KINDS.degraded, message: m.formatDegradedRefusal(res.error) };
  const r = m.readOpenThisPr(res.path);
  if (r.state === "error") return { kind: KINDS.degraded, message: m.formatDegradedRefusal(r.reason) };
  if (r.open.length === 0) return null;
  return { kind: KINDS.open, message: m.formatOpenThisPrRefusal(res.path, r.open) };
}

module.exports = { checkWriteCodeThisPr, THIS_PR_GATES, THIS_PR_OPEN_KINDS: KINDS };
