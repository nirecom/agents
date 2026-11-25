"use strict";

// Atomic WORKTREE_NOTES.md write (tmp + rename), shared by bin/worktree-notes-triage.js and the
// THIS_PR_FINDING_ACCEPTED sentinel handler. writeNotesAtomic(resolved, text, onError?) -> boolean.

const fs = require("fs");

function writeNotesAtomic(resolved, text, onError) {
  const tmp = `${resolved}.tmp`;
  try {
    fs.writeFileSync(tmp, text, "utf8");
    fs.renameSync(tmp, resolved);
    return true;
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch { /* ignore cleanup error */ }
    if (typeof onError === "function") onError(`atomic write failed: ${e.message}`);
    return false;
  }
}

module.exports = { writeNotesAtomic };
