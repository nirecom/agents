"use strict";
// Temporary (#2434): deleted with this folder per the deletion-condition in control-dir.js.
// Moves legacy PLANS_DIR control files into <CLAUDE_WORKFLOW_DIR>/<sid>.control/.
// migrateSession: one sid, immediately. migrateAll: every sid past the quiet
// period, best-effort, never throws. ensureMigrated: the controlPath hook;
// ensureSessionMigrated: the sessionControlDir hook.
// Paths are built here directly; this module never calls controlPath.
const fs = require("fs");
const path = require("path");
const { getWorkflowDir } = require("../../../workflow-state/state-io/core");
const { getWorkflowPlansDir } = require("../../workflow-plans-dir");
const { legacyBasename, parsePlansEntry } = require("../../plans-artifact-registry");
const { MIGRATABLE, readEntries, listSessionEntries, groupAllSessions } = require("./plan");
const { applyBatch } = require("./apply");
const { readCursor, canSkipScan, writeCursor } = require("./cursor");

const QUIET_MS = 10 * 60 * 1000;
const STALE_TMP_MS = 24 * 60 * 60 * 1000;
const STALE_TMP_RE = /\.migrating\..*\.tmp$/;

let running = false;

function trace(msg) {
  if (process.env.CONTROL_MIGRATION_TRACE === "1") process.stderr.write(`control-migration: ${msg}\n`);
}

function migrateSessionSync(sid, opts) {
  // Same sid alphabet as the control dir it fills (lazy: control-dir.js requires this module).
  require("../../../workflow-state/state-io/control-dir").assertValidControlSid(sid);
  if (running) return [];
  running = true;
  try {
    const rows = applyBatch(sid, listSessionEntries(sid, getWorkflowPlansDir()), { wf: getWorkflowDir() });
    const only = opts && opts.only;
    if (only && !rows.some((r) => r.name === only)) {
      const done = fs.existsSync(path.join(getWorkflowDir(), `${sid}.control`, only));
      if (done) rows.push({ sid, name: only, outcome: "identical" });
    }
    return rows;
  } finally {
    running = false;
  }
}

function migrateSession(sid, opts) {
  try {
    return Promise.resolve(migrateSessionSync(sid, opts));
  } catch (e) {
    return Promise.reject(e);
  }
}

function isRegularFile(p) {
  try { return fs.lstatSync(p).isFile(); } catch (_) { return false; }
}

const cleanSids = new Set();

// The batch is atomic: a failed sibling means this name's state is not yet trustworthy either.
function ensureSiblingsMigrated(sid, name, dst, plansDir, legacyPath, ErrorClass) {
  if (cleanSids.has(sid) || fs.existsSync(dst)) return;
  if (listSessionEntries(sid, plansDir).length === 0) { cleanSids.add(sid); return; }
  const bad = migrateSessionSync(sid).find((r) => r.outcome === "failed");
  if (bad) throw new ErrorClass({ sid, name, legacyPath, cause: new Error(bad.error) });
}

// Called from controlPath: the session's own file migrates now, or the caller fails closed.
function ensureMigrated(sid, name, dst, ErrorClass) {
  let plansDir;
  try { plansDir = getWorkflowPlansDir(); } catch (_) { return; }
  const legacyName = legacyBasename(sid, name);
  const legacyPath = path.join(plansDir, legacyName);
  if (!isRegularFile(legacyPath)) return ensureSiblingsMigrated(sid, name, dst, plansDir, legacyPath, ErrorClass);
  const parsed = parsePlansEntry(legacyName);
  if (!parsed || parsed.verdict !== "control" || parsed.sid !== sid || !MIGRATABLE.has(parsed.kind)) return;
  const rows = migrateSessionSync(sid, { only: name });
  const row = rows.find((r) => r.name === name);
  if (row && row.outcome === "failed") {
    throw new ErrorClass({ sid, name, legacyPath, cause: new Error(row.error) });
  }
  if (!fs.existsSync(dst)) {
    throw new ErrorClass({ sid, name, legacyPath, cause: new Error("destination missing after migration") });
  }
}

// Called from sessionControlDir: a caller of the whole dir needs every legacy file moved first.
function ensureSessionMigrated(sid, ErrorClass) {
  let plansDir;
  try { plansDir = getWorkflowPlansDir(); } catch (_) { return; }
  if (cleanSids.has(sid)) return;
  if (listSessionEntries(sid, plansDir).length === 0) { cleanSids.add(sid); return; }
  const bad = migrateSessionSync(sid).find((r) => r.outcome === "failed");
  if (!bad) return;
  const legacyPath = path.join(plansDir, legacyBasename(sid, bad.name));
  throw new ErrorClass({ sid, name: bad.name, legacyPath, cause: new Error(bad.error) });
}

function newestMtime(entries) {
  let newest = 0;
  for (const e of entries) {
    try { newest = Math.max(newest, fs.lstatSync(e.src).mtimeMs); } catch (_) { /* vanished */ }
  }
  return newest;
}

function sweepStaleTmps(wf, now) {
  for (const d of readEntries(wf)) {
    if (!d.isDirectory() || !d.name.endsWith(".control")) continue;
    const ctl = path.join(wf, d.name);
    for (const f of readEntries(ctl)) {
      if (!f.isFile() || !STALE_TMP_RE.test(f.name)) continue;
      const p = path.join(ctl, f.name);
      try { if (now - fs.statSync(p).mtimeMs > STALE_TMP_MS) fs.unlinkSync(p); } catch (_) { /* raced */ }
    }
  }
}

function migrateAllSync(opts) {
  const o = opts || {};
  const budgetMs = typeof o.budgetMs === "number" ? o.budgetMs : 2000;
  const start = Date.now();
  // Half-pinned env (a test fixture) would sweep the real plans dir into a throwaway dir.
  if (!process.env.CLAUDE_WORKFLOW_DIR !== !process.env.WORKFLOW_PLANS_DIR) return { complete: false, failed: 0, skipped: "half-pinned" };
  const wf = getWorkflowDir();
  const plansDir = getWorkflowPlansDir();
  let st;
  try { st = fs.statSync(plansDir); } catch (_) { return { complete: true, failed: 0 }; }
  const prior = readCursor(wf);
  if (canSkipScan(prior, plansDir, st.mtimeMs, start)) return prior;
  trace(`readdir ${plansDir}`);
  const groups = groupAllSessions(readEntries(plansDir), plansDir);
  sweepStaleTmps(wf, start);
  let complete = true;
  let retryAfter = null;
  let failed = 0;
  for (const [sid, entries] of groups) {
    if (sid === o.excludeSid) continue;
    if (Date.now() >= start + budgetMs) { complete = false; break; }
    const newest = newestMtime(entries);
    if (start - newest < QUIET_MS) {
      complete = false;
      retryAfter = Math.min(retryAfter === null ? Infinity : retryAfter, newest + QUIET_MS);
      continue;
    }
    const bad = applyBatch(sid, entries, { wf }).filter((r) => r.outcome === "failed");
    if (bad.length > 0) {
      complete = false;
      failed += bad.length;
      process.stderr.write(`control-migration: ${bad.length} file(s) of ${sid} not migrated: ${bad[0].error}\n`);
    }
  }
  const cursor = { plansDir, plansDirMtimeMs: st.mtimeMs, scannedAt: start, complete, retryAfter, failed };
  writeCursor(wf, cursor);
  return cursor;
}

function migrateAll(opts) {
  if (running) return Promise.resolve({ complete: false, reentered: true, failed: 0 });
  running = true;
  try {
    return Promise.resolve(migrateAllSync(opts));
  } catch (e) {
    process.stderr.write(`control-migration: scan aborted: ${(e && e.message) || e}\n`);
    return Promise.resolve({ complete: false, failed: 0 });
  } finally {
    running = false;
  }
}

module.exports = { QUIET_MS, migrateSession, migrateSessionSync, migrateAll, ensureMigrated, ensureSessionMigrated };
