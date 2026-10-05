"use strict";
// hooks/lib/rtk-guard-audit.js — JSONL guard-reject log. Size-rotating, fail-open.
// The lock/rotation machinery lives in jsonl-rotating-log.js; this file owns the log name.

const path = require("path");
const shared = require("./jsonl-rotating-log");

const LOG_FORMAT_VERSION = 1;
const MAX_BYTES = shared.DEFAULT_MAX_BYTES;
const MAX_ROTATED = shared.DEFAULT_MAX_ROTATED;
const LOCK_STALE_MS = shared.LOCK_STALE_MS;
const LOCK_RETRY_MS = shared.LOCK_RETRY_MS;

function resolveLogPath(opts = {}) {
  if (opts.logPath) return opts.logPath;
  return path.join(shared.resolveLogDir({}), "rtk-guard-audit.log");
}

function rotate(logPath) {
  shared.rotate(logPath, MAX_ROTATED);
}

function recordGuardReject(name, cmd, opts = {}) {
  const ts = new Date(opts.now ? opts.now() : Date.now()).toISOString();
  const record = { v: LOG_FORMAT_VERSION, ts, guard: name, action: "reject", command: cmd };
  shared.appendJsonlRotating(resolveLogPath(opts), record, {
    maxBytes: MAX_BYTES,
    maxRotated: MAX_ROTATED,
    lockPath: opts.lockPath,
  });
}

module.exports = {
  recordGuardReject,
  rotate,
  resolveLogPath,
  LOG_FORMAT_VERSION,
  MAX_BYTES,
  MAX_ROTATED,
  LOCK_STALE_MS,
  LOCK_RETRY_MS,
};
