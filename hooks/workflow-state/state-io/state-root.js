"use strict";
// hooks/workflow-state/state-io/state-root.js
// The one resolver for the workflow state root and each session's state dir (#2511).
// Default root: <home>/.workflow-state; a pin (opts.pin, else $WORKFLOW_STATE_DIR) wins.
// opts = { pin, home, envFallback }: envFallback:false never reads process.env.
// Policy and inventory: docs/architecture/claude-code/state-dirs.md.
const fs = require("fs");
const os = require("os");
const path = require("path");

// The #2025 C9 path-token alphabet: a dot is legal inside a sid, but never leading, never `..`.
const STATE_SID_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/;

function assertValidStateSid(sid) {
  if (typeof sid !== "string" || !STATE_SID_RE.test(sid) || sid.includes("..")) {
    throw new Error(`Invalid sessionId: ${JSON.stringify(sid)}`);
  }
}

// A relative pin would resolve against whatever cwd the reading process has, so two
// hooks could disagree on the root: reject it (the WORKFLOW_PLANS_DIR precedent).
// On Windows a driveless `/tmp/x` (or `\x`, or UNC) is cwd-drive-relative to Node but
// MSYS-root-relative to Git Bash, so only a drive form (`C:\`, `C:/`, MSYS `/c/`) is absolute.
const WIN_DRIVE_ABS_RE = /^[A-Za-z]:[\\/]/;

function isAbsolutePin(w) {
  return process.platform === "win32" ? WIN_DRIVE_ABS_RE.test(w) : path.isAbsolute(w);
}

function normalizePin(raw) {
  const v = typeof raw === "string" ? raw.trim() : "";
  if (!v) return null;
  const { toWindowsPath } = require("../../lib/branch-diff");
  const w = toWindowsPath(v);
  if (!isAbsolutePin(w)) {
    throw new Error(`WORKFLOW_STATE_DIR must be an absolute path (tilde is not expanded). Got: ${JSON.stringify(raw)}`);
  }
  return path.resolve(w);
}

function resolvePin(opts) {
  const o = opts || {};
  if (o.pin) return normalizePin(o.pin);
  if (o.envFallback !== false) return normalizePin(process.env.WORKFLOW_STATE_DIR);
  return null;
}

function homeOf(opts) {
  return (opts && opts.home) || os.homedir();
}

function getStateRoot(opts) {
  return resolvePin(opts) || path.join(homeOf(opts), ".workflow-state");
}

// Sessions already confirmed in the new root (key: newRoot + NUL + sid).
const newRootCache = new Set();

function getSessionStateDir(sid, opts) {
  assertValidStateSid(sid);
  const pin = resolvePin(opts);
  if (pin) return pin;
  const newRoot = getStateRoot(opts);
  // --- BEGIN temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration added 2026-10-04 ---
  // deletion-condition: remove when bin/state-dir-relocation remaining exits 0 (no session with a <sid>.json or <sid>.control left in the legacy dir, any sid shape); also delete skills/session-close SC-9; review by 2027-01-04
  const legacy = require("../../lib/temporary-migrations/state-dir-relocation/legacy");
  const home = homeOf(opts);
  const key = `${newRoot}\0${sid}`;
  if (newRootCache.has(key)) return newRoot;
  if (fs.existsSync(path.join(newRoot, `${sid}.json`))) {
    newRootCache.add(key);
    return newRoot;
  }
  if (legacy.isLegacySession(sid, { newRoot, home })) return legacy.LEGACY_ROOT(home);
  // --- END temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration ---
  return newRoot;
}

function listStateRoots(opts) {
  const pin = resolvePin(opts);
  if (pin) return [pin];
  const roots = [getStateRoot(opts)];
  // --- BEGIN temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration added 2026-10-04 ---
  // deletion-condition: remove when bin/state-dir-relocation remaining exits 0 (no session with a <sid>.json or <sid>.control left in the legacy dir, any sid shape); also delete skills/session-close SC-9; review by 2027-01-04
  // Listed whether or not it exists: a root created after this call (a legacy writer
  // racing a guard) must still be covered. Every caller reads an absent legacy root as empty.
  const legacyRoot = require("../../lib/temporary-migrations/state-dir-relocation/legacy").LEGACY_ROOT(homeOf(opts));
  if (!roots.includes(legacyRoot)) roots.push(legacyRoot);
  // --- END temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration ---
  return roots;
}

module.exports = {
  STATE_SID_RE,
  CONTROL_SID_RE: STATE_SID_RE,
  assertValidStateSid,
  getStateRoot,
  getSessionStateDir,
  listStateRoots,
};
