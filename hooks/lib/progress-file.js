"use strict";
// hooks/lib/progress-file.js
// session-progress.md (#2594): the one file the main conversation's model writes across every
// generation of a handed-off session. Its name carries the first generation's sid (the root
// sid), so each generation copies the root sid its donor saved; walking the inherited_from
// chain is only the fallback. ensureProgressFile never overwrites a non-empty file: only a
// 0-byte one (the trace of an interrupted first write) is restored to the template.
// Design: docs/architecture/claude-code/progress-file.md.

const fs = require("fs");
const path = require("path");
const { sidecarPath, readSidecar, writeSidecar } = require("./handoff-sidecar");
const { withLock } = require("./jsonl-rotating-log");
const { getPlansArtifactPath } = require("./plans-artifact-registry");

const PRESSURE_SUFFIX = "progress-pressure.json";
const CURRENT_STATE_SECTION = "Current state";
const TEMPLATE_PATH = path.join(__dirname, "..", "..", "templates", "progress.md");

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
// A patch whose every value is JSON-equal to the current record skips the write.
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
      const changed = Object.keys(patch).some((k) => JSON.stringify(patch[k]) !== JSON.stringify(cur[k]));
      if (changed && !writeSidecar(sid, PRESSURE_SUFFIX, Object.assign({}, cur, patch))) return null;
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

const MAX_CHAIN_DEPTH = 64;

// pinCapRoot(chain, root) -> root — saves root in every walked generation that has none yet, so
// the newest sid, any older sid of this walk, and every later descendant (which stops at the
// first saved root) share one progress file. Compare-and-set: an already saved root wins.
function pinCapRoot(chain, root) {
  for (const s of chain) mergePressure(s, { root_sid: root }, { onlyIf: (cur) => !isValidSid(cur.root_sid) });
  return root;
}

// resolveRootSid(sid) -> the root sid; the own sid when nothing better is known. Never throws.
// A walk past MAX_CHAIN_DEPTH hops roots the lineage at the oldest sid it reached (pinCapRoot).
function resolveRootSid(sid) {
  try {
    if (!isValidSid(sid)) return sid;
    const own = savedRootSid(sid);
    if (own) return own;
    const chain = [sid];
    const seen = new Set(chain);
    for (;;) {
      if (chain.length > MAX_CHAIN_DEPTH) return pinCapRoot(chain, chain[chain.length - 1]);
      const donor = donorOf(chain[chain.length - 1]);
      if (!donor) return chain[chain.length - 1];
      // A cycle has no first generation, so every member and every tail into it agrees on
      // the cycle's smallest sid: one progress file whichever member asks.
      if (seen.has(donor)) return chain.slice(chain.indexOf(donor)).sort()[0];
      const saved = savedRootSid(donor);
      if (saved) return saved;
      seen.add(donor);
      chain.push(donor);
    }
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

// isEmptyRegularFile(file) -> true for a 0-byte regular file only. A non-empty file — even a
// strict byte-prefix of the template — may be the model's edit (trailing sections deleted).
function isEmptyRegularFile(file) {
  try {
    const st = fs.lstatSync(file);
    return st.isFile() && st.size === 0;
  } catch (_) {
    return false;
  }
}

// writeTemplate(file, tpl, replace) -> bool — the template reaches file complete or not at all:
// it is written to a temp file, then hard-linked into place (fails on an existing file) or,
// when replacing a 0-byte file, renamed over it. A file system without hard links falls back to a
// plain exclusive write. Throws (EEXIST when another writer created file first).
function writeTemplate(file, tpl, replace) {
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, tpl, { flag: "wx" });
  try {
    // Re-checked right before the rename: a write that landed since the first check is kept.
    if (replace && !isEmptyRegularFile(file)) return false;
    if (replace) fs.renameSync(tmp, file);
    else fs.linkSync(tmp, file);
  } catch (e) {
    if (replace || (e && e.code === "EEXIST")) throw e;
    fs.writeFileSync(file, tpl, { flag: "wx" });
  } finally {
    try { fs.unlinkSync(tmp); } catch (_) { /* renamed away */ }
  }
  return true;
}

// ensureProgressFile(sid) -> {path, created} | {path:null, created:false}. Creates the file
// from the template only when absent, and restores it only over a 0-byte regular file (the
// trace of an interrupted first write); any non-empty file is never touched. A path is returned only
// when the target is (or becomes) a regular file; a directory, symlink, or failed write
// yields {path:null}. Never throws.
function ensureProgressFile(sid) {
  try {
    if (!isValidSid(sid)) return { path: null, created: false };
    const rootSid = resolveRootSid(sid);
    const file = getPlansArtifactPath(rootSid, "progress");
    const tpl = Buffer.from(renderTemplate(rootSid), "utf8");
    let present = true;
    try { fs.lstatSync(file); } catch (_) { present = false; }
    if (present) {
      if (!isRegularFile(file)) return { path: null, created: false };
      if (!isEmptyRegularFile(file)) return { path: file, created: false };
      return { path: file, created: writeTemplate(file, tpl, true) };
    }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    try {
      writeTemplate(file, tpl, false);
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
  CURRENT_STATE_SECTION,
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
