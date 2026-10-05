"use strict";
// hooks/lib/jev/state-paths.js — where per-session Jev state lives, and the id guard
// every path built from a hook payload goes through (session_id, tool_use_id).

const fs = require("fs");
const os = require("os");
const path = require("path");

const ID_RE = /^[A-Za-z0-9._-]{1,128}$/;

// A payload id becomes a path segment only when it is charset-limited and not a
// dot-segment; anything else is refused before any filesystem call.
function isValidId(id) {
  return typeof id === "string" && ID_RE.test(id) && !id.includes("..") && id !== ".";
}

function jevStateDir() {
  const stateDir = process.env.AGENTS_STATE_DIR;
  return stateDir ? path.join(stateDir, "jev") : path.join(os.homedir(), ".agents", "jev");
}

function sessionDir(sid) {
  if (!isValidId(sid)) throw new Error("invalid session id");
  return path.join(jevStateDir(), sid);
}

function readJson(p) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch (_e) {
    return null;
  }
}

// Write to a pid-suffixed sibling, then rename: readers never see a partial file.
function writeJsonAtomic(p, obj) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const tmp = `${p}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, p);
}

module.exports = { ID_RE, isValidId, jevStateDir, sessionDir, readJson, writeJsonAtomic };
