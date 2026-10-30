"use strict";
// hooks/lib/progress-file.js
// session-progress.md (#2594): the one file the main conversation's model writes across every
// generation of a session chain. Its name carries first_session_id, resolved from the state by
// hooks/workflow-state/state-ancestry.js (#2748); nothing is pinned. ensureProgressFile never
// overwrites a non-empty file: only a 0-byte one (the trace of an interrupted first write) is
// restored to the template. The pressure control file lives in progress-pressure-sidecar.js and
// is re-exported here for existing callers.
// Design: docs/architecture/claude-code/progress-file.md.

const fs = require("fs");
const path = require("path");
const { getPlansArtifactPath } = require("./plans-artifact-registry");
const sidecar = require("./progress-pressure-sidecar");
const { isValidSid, resolveFirstSid } = require("../workflow-state/state-ancestry");

const CURRENT_STATE_SECTION = "Current state";
const TEMPLATE_PATH = path.join(__dirname, "..", "..", "templates", "progress.md");

// progressPathFor(sid) -> <plans dir>/<first_session_id>-session-progress.md, or null for an invalid sid.
function progressPathFor(sid) {
  if (!isValidSid(sid)) return null;
  try { return getPlansArtifactPath(resolveFirstSid(sid), "progress"); } catch (_) { return null; }
}

function renderTemplate(firstSid) {
  const body = fs.readFileSync(TEMPLATE_PATH, "utf8");
  const fill = { INTENT_PATH: "intent", OUTLINE_PATH: "outline", DETAIL_PATH: "detail" };
  return body.replace(/\{\{(INTENT_PATH|OUTLINE_PATH|DETAIL_PATH)\}\}/g, (_m, key) => getPlansArtifactPath(firstSid, fill[key]));
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
    const firstSid = resolveFirstSid(sid);
    const file = getPlansArtifactPath(firstSid, "progress");
    const tpl = Buffer.from(renderTemplate(firstSid), "utf8");
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
  return sidecar.updatePressure(sid, (cur) => {
    const counts = Object.assign({}, cur.counts || {});
    counts.update_progress = (Number(counts.update_progress) || 0) + 1;
    return { patch: { counts }, result: true };
  }) === true;
}

module.exports = {
  PRESSURE_SUFFIX: sidecar.PRESSURE_SUFFIX,
  CURRENT_STATE_SECTION,
  TEMPLATE_PATH,
  isValidSid,
  readPressure: sidecar.readPressure,
  mergePressure: sidecar.mergePressure,
  updatePressure: sidecar.updatePressure,
  resolveFirstSid,
  // Pre-#2748 name kept for existing callers.
  resolveRootSid: resolveFirstSid,
  progressPathFor,
  renderTemplate,
  isRegularFile,
  ensureProgressFile,
  bumpUpdateProgress,
};
