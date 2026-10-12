"use strict";
// hooks/lib/confirm-deny-counter.js — how many CONFIRM_<STAGE> echoes in a row confirm-checkpoint
// denied for one (session, stage) (#2513). Stored as {count} in the session control dir
// (confirm-link-deny-<stage>.json). Every function returns null when the file cannot be read or
// written, so the caller can fail open instead of denying on unknown state.

const fs = require("fs");

function fileFor(sid, stage, forWrite) {
  const { controlPath } = require("../workflow-state/state-io/control-dir");
  return controlPath(sid, `confirm-link-deny-${stage}.json`, forWrite ? { forWrite: true } : undefined);
}

// read(sid, stage) -> the stored count (0 when absent), or null when unreadable.
function read(sid, stage) {
  try {
    if (!sid || !stage) return null;
    let raw;
    try {
      raw = fs.readFileSync(fileFor(sid, stage, false), "utf8");
    } catch (e) {
      if (e && e.code === "ENOENT") return 0;
      return null;
    }
    const parsed = JSON.parse(raw);
    const n = parsed && Number.isInteger(parsed.count) && parsed.count >= 0 ? parsed.count : null;
    return n;
  } catch (_) {
    return null;
  }
}

function write(sid, stage, count) {
  try {
    const file = fileFor(sid, stage, true);
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify({ count }) + "\n");
    fs.renameSync(tmp, file);
    return count;
  } catch (_) {
    return null;
  }
}

// bump(sid, stage) -> the count after this deny candidate, or null.
function bump(sid, stage) {
  const cur = read(sid, stage);
  if (cur === null) return null;
  return write(sid, stage, cur + 1);
}

// reset(sid, stage) -> 0, or null when the counter cannot be written.
function reset(sid, stage) {
  if (read(sid, stage) === 0) return 0;
  return write(sid, stage, 0);
}

module.exports = { read, bump, reset };
