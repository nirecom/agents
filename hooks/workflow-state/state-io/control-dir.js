"use strict";
// hooks/workflow-state/state-io/control-dir.js
// The one resolver for per-session control files: <CLAUDE_WORKFLOW_DIR>/<sid>.control/<name>.
// Policy and inventory: docs/architecture/claude-code/state-dirs.md.
const fs = require("fs");
const path = require("path");
const { getWorkflowDir } = require("./core");

const CONTROL_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
// The #2025 C9 path-token alphabet: a dot is legal inside a sid, but never leading, never `..`.
const CONTROL_SID_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/;

function assertValidControlSid(sid) {
  if (typeof sid !== "string" || !CONTROL_SID_RE.test(sid) || sid.includes("..")) {
    throw new Error(`Invalid sessionId: ${JSON.stringify(sid)}`);
  }
}

class ControlMigrationError extends Error {
  constructor({ sid, name, legacyPath, cause } = {}) {
    const why = cause && cause.message ? cause.message : String(cause || "migration did not publish");
    super(`control-dir: legacy control file ${sid}-${name} could not be migrated (${legacyPath}): ${why}`);
    this.name = "ControlMigrationError";
    this.sid = sid;
    this.controlName = name;
    this.legacyPath = legacyPath;
    this.cause = cause;
  }

  // A forWrite resolve appends this log line; readers only diagnose on stderr (diagnoseControlMigration).
  log() {
    appendMigrationLog(`failed sid=${this.sid} name=${this.controlName} legacy=${this.legacyPath} ${this.message}`);
  }
}

const diagnosedMigrations = new Set();

// A reader that degrades on ControlMigrationError reports it here: one stderr line per file per process.
function diagnoseControlMigration(e, who) {
  if (!(e instanceof ControlMigrationError)) return false;
  const key = `${e.sid}/${e.controlName}`;
  if (diagnosedMigrations.has(key)) return true;
  diagnosedMigrations.add(key);
  try {
    process.stderr.write(`${who}: ${String(e.message).replace(/\s*[\r\n]+\s*/g, " ")}\n`);
  } catch (_) { /* the diagnostic never changes the reader's outcome */ }
  return true;
}

function appendMigrationLog(line) {
  try {
    const wf = getWorkflowDir();
    fs.mkdirSync(wf, { recursive: true });
    fs.appendFileSync(path.join(wf, "control-migration.log"), `${new Date().toISOString()} ${line}\n`);
  } catch (_) { /* the log is diagnostic only */ }
}

function getSessionControlDir(sid) {
  assertValidControlSid(sid);
  return path.join(getWorkflowDir(), `${sid}.control`);
}

function assertControlName(name) {
  if (typeof name !== "string" || !CONTROL_NAME_RE.test(name) || name.includes("..")) {
    throw new Error(`control-dir: invalid control file name: ${JSON.stringify(name)}`);
  }
}

// A <sid>.control that is a symlink or a non-directory is refused for reads and writes alike.
function assertRealControlDir(dir) {
  let st;
  try { st = fs.lstatSync(dir); } catch (e) {
    if (e.code === "ENOENT") return false;
    throw e;
  }
  if (st.isSymbolicLink() || !st.isDirectory()) {
    throw new Error(`control-dir: ${dir} is not a real directory (symlink or file refused)`);
  }
  return true;
}

function ensureControlDir(dir) {
  if (assertRealControlDir(dir)) return;
  fs.mkdirSync(path.dirname(dir), { recursive: true });
  try { fs.mkdirSync(dir); } catch (e) { if (e.code !== "EEXIST") throw e; }
  assertRealControlDir(dir);
}

function controlPath(sid, name, opts) {
  const dir = getSessionControlDir(sid);
  assertControlName(name);
  const forWrite = !!(opts && opts.forWrite);
  if (forWrite) ensureControlDir(dir);
  else assertRealControlDir(dir);
  const dst = path.join(dir, name);
  // --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
  // deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/, bin/migrate-control-dir and the legacy-argument shims; keep guard (c) until then
  const mig = require("../../lib/temporary-migrations/control-dir-split");
  try {
    mig.ensureMigrated(sid, name, dst, ControlMigrationError);
  } catch (e) {
    if (forWrite && e instanceof ControlMigrationError) e.log();
    throw e;
  }
  if (forWrite) mig.migrateAll({ budgetMs: 200, excludeSid: sid });
  // --- END temporary: plans-dir control files -> workflow control dir migration ---
  return dst;
}

// The directory itself, refused when it is a symlink; created only for writers.
// Its whole legacy content migrates first, fail-closed exactly as in controlPath.
function sessionControlDir(sid, opts) {
  const dir = getSessionControlDir(sid);
  const forWrite = !!(opts && opts.forWrite);
  if (forWrite) ensureControlDir(dir);
  else assertRealControlDir(dir);
  // --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
  // deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/, bin/migrate-control-dir and the legacy-argument shims; keep guard (c) until then
  const mig = require("../../lib/temporary-migrations/control-dir-split");
  try {
    mig.ensureSessionMigrated(sid, ControlMigrationError);
  } catch (e) {
    if (forWrite && e instanceof ControlMigrationError) e.log();
    throw e;
  }
  if (forWrite) mig.migrateAll({ budgetMs: 200, excludeSid: sid });
  // --- END temporary: plans-dir control files -> workflow control dir migration ---
  return dir;
}

module.exports = {
  CONTROL_NAME_RE,
  CONTROL_SID_RE,
  assertValidControlSid,
  ControlMigrationError,
  diagnoseControlMigration,
  getSessionControlDir,
  sessionControlDir,
  controlPath,
  assertControlName,
  appendMigrationLog,
};
