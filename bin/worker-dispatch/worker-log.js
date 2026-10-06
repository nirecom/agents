"use strict";
// bin/worker-dispatch/worker-log.js — timestamped worker logs (#2558).
// The dispatcher decides where logs go (ctx.logDir); this module never picks a destination.
// Location policy: docs/architecture/claude-code/state-dirs.md "Worker logs".

const path = require("path");

const LABEL_RE = /^[a-z0-9][a-z0-9.-]*$/;

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

function logPath(ctx, label, opts) {
  if (typeof label !== "string" || !LABEL_RE.test(label)) {
    throw new Error(`worker-log: invalid log label: ${JSON.stringify(label)}`);
  }
  if (!ctx || !ctx.logDir) throw new Error("worker-log: no log directory for this run");
  return path.join(ctx.logDir, `${(opts && opts.stamp) || stamp()}-${label}`);
}

function writeLog(ctx, label, body, opts) {
  return ctx.fsguard.writeFile(logPath(ctx, label, opts), body);
}

function tryWriteLog(ctx, label, body, opts) {
  try {
    return writeLog(ctx, label, body, opts);
  } catch (_e) {
    return "(none)";
  }
}

module.exports = { stamp, logPath, writeLog, tryWriteLog };
