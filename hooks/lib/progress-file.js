"use strict";
// hooks/lib/progress-file.js
// session-progress.md (#2594): the one file the main conversation's model writes across every
// generation of a handed-off session. Its name carries the first generation's sid (the root
// sid), so each generation copies the root sid its donor saved; walking the inherited_from
// chain is only the fallback. ensureProgressFile never overwrites what the model wrote.
// Design: docs/architecture/claude-code/progress-file.md.

const fs = require("fs");
const path = require("path");
const { sidecarPath, readSidecar, writeSidecar } = require("./handoff-sidecar");
const { withLock } = require("./jsonl-rotating-log");
const { getPlansArtifactPath } = require("./plans-artifact-registry");

const PRESSURE_SUFFIX = "progress-pressure.json";
const TEMPLATE_PATH = path.join(__dirname, "..", "..", "templates", "progress.md");
const MAX_CHAIN_DEPTH = 8;

function stateIo() {
  return require("../workflow-state/state-io");
}

function isValidSid(sid) {
  return typeof sid === "string" && stateIo().SESSION_ID_VALID_RE.test(sid);
}

function readPressure(sid) {
  return readSidecar(sid, PRESSURE_SUFFIX);
}

function lockOpts(opts) {
  return opts && typeof opts.lockWaitMs === "number" ? { maxWaitMs: opts.lockWaitMs } : null;
}

// mergePressure(sid, patch, opts) -> bool — read, merge, write: every writer keeps the other keys.
// The lock serializes concurrent hooks so no writer drops another's keys. Never throws.
// opts.lockWaitMs bounds the lock wait (withLock maxWaitMs); a timeout returns false.
// opts.onlyIf(cur) -> bool makes it a compare-and-set: false under the lock skips the write.
function mergePressure(sid, patch, opts) {
  try {
    const file = sidecarPath(sid, PRESSURE_SUFFIX, { forWrite: true });
    if (file === null) return false;
    return withLock(`${file}.lock`, lockOpts(opts), () => {
      const cur = readPressure(sid) || {};
      if (opts && typeof opts.onlyIf === "function" && opts.onlyIf(cur) !== true) return false;
      return writeSidecar(sid, PRESSURE_SUFFIX, Object.assign({}, cur, patch));
    });
  } catch (_) {
    return false;
  }
}

// updatePressure(sid, fn, opts) -> result | null — fn(cur) -> {patch, result} | null runs under the
// lock, so a read-decide-write cannot race another hook. Null on no-op, lock or write failure.
// The lock is not reentrant: fn must never call mergePressure or updatePressure. Never throws.
// opts.lockWaitMs bounds the lock wait; a timeout returns null and fn is not run.
function updatePressure(sid, fn, opts) {
  try {
    const file = sidecarPath(sid, PRESSURE_SUFFIX, { forWrite: true });
    if (file === null) return null;
    return withLock(`${file}.lock`, lockOpts(opts), () => {
      const cur = readPressure(sid) || {};
      const out = fn(cur);
      if (!out) return null;
      const patch = out.patch || {};
      if (Object.keys(patch).length > 0 && !writeSidecar(sid, PRESSURE_SUFFIX, Object.assign({}, cur, patch))) return null;
      return out.result === undefined ? null : out.result;
    });
  } catch (_) {
    return null;
  }
}

function savedRootSid(sid) {
  const p = readPressure(sid);
  return p && isValidSid(p.root_sid) ? p.root_sid : null;
}

// donorOf(sid) -> the sid named by the last session-inheritance event, or null.
function donorOf(sid) {
  let st = null;
  try { st = stateIo().readState(sid); } catch (_) { st = null; }
  const events = st && Array.isArray(st.events) ? st.events : [];
  for (let i = events.length - 1; i >= 0; i--) {
    const e = events[i];
    if (e && e.provenance === "backfilled" && isValidSid(e.inherited_from)) return e.inherited_from;
  }
  return null;
}

// resolveRootSid(sid) -> the root sid; the own sid when nothing better is known. Never throws.
function resolveRootSid(sid) {
  try {
    if (!isValidSid(sid)) return sid;
    const own = savedRootSid(sid);
    if (own) return own;
    let cur = sid;
    const seen = new Set([sid]);
    for (let depth = 0; depth < MAX_CHAIN_DEPTH; depth++) {
      const donor = donorOf(cur);
      if (!donor || seen.has(donor)) return cur;
      const saved = savedRootSid(donor);
      if (saved) return saved;
      seen.add(donor);
      cur = donor;
    }
    return cur;
  } catch (_) {
    return sid;
  }
}

// progressPathFor(sid) -> <plans dir>/<root sid>-session-progress.md, or null for an invalid sid.
function progressPathFor(sid) {
  if (!isValidSid(sid)) return null;
  try { return getPlansArtifactPath(resolveRootSid(sid), "progress"); } catch (_) { return null; }
}

function renderTemplate(rootSid) {
  const body = fs.readFileSync(TEMPLATE_PATH, "utf8");
  const fill = { INTENT_PATH: "intent", OUTLINE_PATH: "outline", DETAIL_PATH: "detail" };
  return body.replace(/\{\{(INTENT_PATH|OUTLINE_PATH|DETAIL_PATH)\}\}/g, (_m, key) => getPlansArtifactPath(rootSid, fill[key]));
}

function isRegularFile(file) {
  try { return fs.lstatSync(file).isFile(); } catch (_) { return false; }
}

// ensureProgressFile(sid) -> {path, created} | {path:null, created:false}. Creates the file
// from the template only when absent (flag "wx"); never overwrites. A path is returned only
// when the target is (or becomes) a regular file; a directory, symlink, or failed write
// yields {path:null}. Never throws.
function ensureProgressFile(sid) {
  try {
    if (!isValidSid(sid)) return { path: null, created: false };
    const rootSid = resolveRootSid(sid);
    const file = getPlansArtifactPath(rootSid, "progress");
    let present = true;
    try { fs.lstatSync(file); } catch (_) { present = false; }
    if (present) return isRegularFile(file) ? { path: file, created: false } : { path: null, created: false };
    fs.mkdirSync(path.dirname(file), { recursive: true });
    try {
      fs.writeFileSync(file, renderTemplate(rootSid), { encoding: "utf8", flag: "wx" });
    } catch (e) {
      if (e && e.code === "EEXIST" && isRegularFile(file)) return { path: file, created: false };
      return { path: null, created: false };
    }
    return { path: file, created: true };
  } catch (_) {
    return { path: null, created: false };
  }
}

// bumpUpdateProgress(sid) -> bool — counts one /update-progress run in the own control file.
function bumpUpdateProgress(sid) {
  return updatePressure(sid, (cur) => {
    const counts = Object.assign({}, cur.counts || {});
    counts.update_progress = (Number(counts.update_progress) || 0) + 1;
    return { patch: { counts }, result: true };
  }) === true;
}

module.exports = {
  PRESSURE_SUFFIX,
  TEMPLATE_PATH,
  isValidSid,
  readPressure,
  mergePressure,
  updatePressure,
  resolveRootSid,
  progressPathFor,
  isRegularFile,
  ensureProgressFile,
  bumpUpdateProgress,
};
