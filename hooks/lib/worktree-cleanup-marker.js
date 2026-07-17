"use strict";
const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function markerPathFor(sid) {
  if (!sid || !SID_RE.test(sid)) return null;
  const plansDir = getWorkflowPlansDir();
  return path.join(plansDir, sid + "-wt-cleanup-active");
}

function createMarker(sid) {
  const p = markerPathFor(sid);
  if (!p) return false;
  try {
    fs.closeSync(fs.openSync(p, "a"));
    return true;
  } catch (_) {
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
  const resolvedSid = rawSid.trim().length > 0 ? rawSid : (process.env.CLAUDE_SESSION_ID || "");

  if (!resolvedSid) {
    process.stderr.write("cleanup-marker: sid unresolved: pass positional arg or set CLAUDE_SESSION_ID\n");
    process.exit(0);
  }

  const p = markerPathFor(resolvedSid);
  if (!p) {
    process.stderr.write("cleanup-marker: invalid sid chars: " + resolvedSid + "\n");
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
