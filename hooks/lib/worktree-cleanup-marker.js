"use strict";
const fs = require("fs");
const { getSessionControlDir, controlPath, diagnoseControlMigration } = require("../workflow-state/state-io/control-dir");

const SID_RE = /^[A-Za-z0-9_-]+$/;
const NAME = "wt-cleanup-active";

// Read-mode resolve (migrates a legacy marker); a refused control dir degrades to the pure path.
// A failed migration yields null: the unmigrated legacy marker must not be shadowed by the new path.
function markerPathFor(sid) {
  if (!sid || !SID_RE.test(sid)) return null;
  try { return controlPath(sid, NAME); } catch (e) {
    if (diagnoseControlMigration(e, "worktree-cleanup-marker")) return null;
    return require("path").join(getSessionControlDir(sid), NAME);
  }
}

function createMarker(sid) {
  if (!sid || !SID_RE.test(sid)) return false;
  try {
    fs.closeSync(fs.openSync(controlPath(sid, NAME, { forWrite: true }), "a"));
    return true;
  } catch (e) {
    diagnoseControlMigration(e, "worktree-cleanup-marker");
    return false;
  }
}

function deleteMarker(sid) {
  const p = markerPathFor(sid);
  if (!p) return false;
  try {
    fs.rmSync(p, { force: true });
    return true;
  } catch (_) {
    return false;
  }
}

if (require.main === module) {
  const command = process.argv[2];
  const rawSid = process.argv[3] || "";
  const resolvedSid = rawSid.trim().length > 0 ? rawSid
    // session-id-ssot: waived (session-scoped marker file) — a misresolved id deletes another session's marker
    : (process.env.CLAUDE_CODE_SESSION_ID || process.env.CLAUDE_SESSION_ID || "");

  if (!resolvedSid) {
    process.stderr.write("cleanup-marker: sid unresolved: pass positional arg or set CLAUDE_CODE_SESSION_ID\n");
    process.exit(0);
  }

  const p = markerPathFor(resolvedSid);
  if (!p) {
    if (!SID_RE.test(resolvedSid)) process.stderr.write("cleanup-marker: invalid sid chars: " + resolvedSid + "\n");
    // A failed migration was already diagnosed; create still resolves forWrite so the migration log records it.
    else if (command === "create") createMarker(resolvedSid);
    process.exit(0);
  }

  if (command === "create") {
    const ok = createMarker(resolvedSid);
    process.stdout.write(ok ? "cleanup marker created: " + p + "\n" : "cleanup marker create failed: " + p + "\n");
    process.exit(0);
  } else if (command === "delete") {
    const ok = deleteMarker(resolvedSid);
    process.stdout.write(ok ? "cleanup marker deleted: " + p + "\n" : "cleanup marker already absent: " + p + "\n");
    process.exit(0);
  } else {
    process.stderr.write("cleanup-marker: unknown command: " + command + "\n");
    process.exit(1);
  }
}

module.exports = { markerPathFor, createMarker, deleteMarker };
