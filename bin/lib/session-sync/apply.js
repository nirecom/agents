"use strict";
// Working-tree writes (#2658): whole files go through tmp + rename, transcripts only grow by append.

const fs = require("node:fs");
const path = require("node:path");
const { decideMtime } = require("./mtime");

function writeAtomic(abs, data) {
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  const tmp = path.join(path.dirname(abs), `.${path.basename(abs)}.session-sync-${process.pid}.tmp`);
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, abs);
}

// Not throwIfNoEntry: a path below a file can raise ENOTDIR, and that means absent here too.
function lstatOrNull(abs) {
  try {
    return fs.lstatSync(abs);
  } catch (_) {
    return null;
  }
}

// statSig(abs) -> {size, mtimeMs} | null (absent or not a regular file).
function statSig(abs) {
  const st = lstatOrNull(abs);
  return st && st.isFile() ? { size: st.size, mtimeMs: st.mtimeMs } : null;
}

const sameSig = (a, b) => (a === null || b === null ? a === b : a.size === b.size && a.mtimeMs === b.mtimeMs);

// pathBlocked(dir, rel) — a file cannot be placed at rel: an ancestor under dir is not a directory,
// or rel itself is one. Checked by shape because the errno of the failed write differs by OS.
function pathBlocked(dir, rel) {
  const parts = rel.split("/");
  for (let i = 1; i < parts.length; i += 1) {
    const st = lstatOrNull(path.join(dir, ...parts.slice(0, i)));
    if (!st) return false;
    if (!st.isDirectory()) return true;
  }
  const target = lstatOrNull(path.join(dir, ...parts));
  return Boolean(target && target.isDirectory());
}

// applyOps(dir, ops, readBlob, stats) -> number of files written.
// op: {rel, kind: "blob"|"text"|"append", blob?, text?, mtime?: boolean, pre?: statSig at classification}
// A write whose target changed since classification is left for the next run: an overwrite would
// lose the new content, and an append could join a line still being written to the remote lines.
// A write the path shape blocks is skipped and not retried, since W keeps what it holds there.
function applyOps(dir, ops, readBlob, stats) {
  let n = 0;
  for (const op of ops) {
    const abs = path.join(dir, ...op.rel.split("/"));
    if (op.kind === "append" && !op.text) continue;
    if (pathBlocked(dir, op.rel)) {
      stats.writeBlocked.count += 1;
      stats.writeBlocked.path = op.rel;
      continue;
    }
    if (op.pre !== undefined && !sameSig(op.pre, statSig(abs))) {
      stats.writeDeferred.count += 1;
      stats.writeDeferred.path = op.rel;
      continue;
    }
    if (op.kind === "append") fs.appendFileSync(abs, op.text);
    else writeAtomic(abs, op.kind === "blob" ? readBlob(op.blob) : op.text);
    n += 1;
    if (op.mtime) setMtime(abs, op.rel, stats);
  }
  return n;
}

// setMtime(abs, rel, stats) — mtime from the last entry timestamp; a refusal is only counted.
function setMtime(abs, rel, stats) {
  let text = "";
  try {
    text = fs.readFileSync(abs, "utf8");
  } catch (_) {
    return;
  }
  const d = decideMtime(text);
  if (d.ok) {
    try {
      fs.utimesSync(abs, d.date, d.date);
      return;
    } catch (_) { /* counted below */ }
  }
  stats.mtimeRejected.count += 1;
  stats.mtimeRejected.path = rel;
}

module.exports = { writeAtomic, applyOps, setMtime, statSig, pathBlocked };
