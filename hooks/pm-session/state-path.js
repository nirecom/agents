"use strict";
// isProtectedPmStatePath(file) (#2941): true for a state file that carries the pm key, in any
// listStateRoots root, and for the atomic writer's tmp form of one (<sid>.json.<pid>.<n>.tmp).
// The pm key has one writer (pm-session/writer.js and bin/pm-state); every other write is blocked.
// isStateFilePath(file): the same name/root match without the pm mark, for unmarked state files.

const fs = require("fs");
const path = require("path");
const { listStateRoots } = require("../workflow-state/state-io/state-root");
const { SESSION_ID_VALID_RE } = require("../workflow-state/state-io/core");
const { toWindowsPath } = require("../lib/branch-diff");

const STATE_NAME_RE = /^([A-Za-z0-9_-]+)\.json(?:\.[^/\\]+\.tmp)?$/i;
const norm = (p) => path.resolve(toWindowsPath(String(p))).replace(/\\/g, "/").toLowerCase();

function carriesPm(file) {
  try {
    const raw = fs.readFileSync(file, "utf8");
    if (!raw.includes('"pm"')) return false;
    const st = JSON.parse(raw);
    return Boolean(st && typeof st === "object" && st.pm && typeof st.pm === "object");
  } catch (_) {
    return false;
  }
}

// stateFileOf(file) -> {abs, root, sid} for <root>/<sid>.json or its tmp form, else null; no pm mark needed.
function stateFileOf(file) {
  if (typeof file !== "string" || !file) return null;
  const abs = path.resolve(toWindowsPath(file));
  const m = path.basename(abs).match(STATE_NAME_RE);
  if (!m || !SESSION_ID_VALID_RE.test(m[1])) return null;
  const dir = norm(path.dirname(abs));
  const root = listStateRoots().find((r) => norm(r) === dir);
  return root ? { abs, root, sid: m[1] } : null;
}

const isStateFilePath = (file) => stateFileOf(file) !== null;

function isProtectedPmStatePath(file) {
  const s = stateFileOf(file);
  return Boolean(s) && (carriesPm(s.abs) || carriesPm(path.join(s.root, `${s.sid}.json`)));
}

module.exports = { isProtectedPmStatePath, isStateFilePath };
