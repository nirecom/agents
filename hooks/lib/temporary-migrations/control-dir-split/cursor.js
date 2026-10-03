"use strict";
// Temporary (#2434): deleted with this folder per the deletion-condition in control-dir.js.
// One global cursor, <wf>/.control-migration-cursor.json, so a settled PLANS_DIR
// costs one stat per session start instead of a readdir.
const fs = require("fs");
const path = require("path");

const CURSOR_NAME = ".control-migration-cursor.json";
const RESCAN_MIN_MS = 10000;
const MTIME_TRUST_MS = 2000;

function cursorPath(wf) {
  return path.join(wf, CURSOR_NAME);
}

function readCursor(wf) {
  try {
    const c = JSON.parse(fs.readFileSync(cursorPath(wf), "utf8"));
    return c && typeof c === "object" ? c : null;
  } catch (_) {
    return null;
  }
}

// Only a complete scan is ever trusted; an incomplete one is always rescanned.
function canSkipScan(cursor, plansDir, plansDirMtimeMs, now) {
  if (!cursor || cursor.complete !== true || cursor.plansDir !== plansDir) return false;
  const mtimeSettled = cursor.plansDirMtimeMs === plansDirMtimeMs
    && cursor.scannedAt - plansDirMtimeMs >= MTIME_TRUST_MS;
  return mtimeSettled || now - cursor.scannedAt < RESCAN_MIN_MS;
}

function writeCursor(wf, cursor) {
  try {
    fs.mkdirSync(wf, { recursive: true });
    const tmp = `${cursorPath(wf)}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, `${JSON.stringify(cursor, null, 2)}\n`);
    fs.renameSync(tmp, cursorPath(wf));
  } catch (_) { /* a lost cursor only costs one extra scan */ }
}

module.exports = { CURSOR_NAME, RESCAN_MIN_MS, readCursor, canSkipScan, writeCursor };
