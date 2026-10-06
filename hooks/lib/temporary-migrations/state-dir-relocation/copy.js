"use strict";
// Temporary (#2511): deleted with this folder per the deletion-condition in state-root.js
// The copy half of a relocation: every file goes through the root rewriter, and each
// copied file is snapshotted (size, mtimeMs) so the post-commit reconcile can tell
// which legacy files changed, appeared, or vanished while the copy was in flight.
const fs = require("fs");
const path = require("path");
const { rewriteBuffer } = require("./rewrite-root");

const LOCKISH_RE = /\.(lock|tmp)$/;

class RelocationError extends Error {
  constructor(code, cause) {
    super(cause ? `${code}: ${cause.message}` : code);
    this.code = code;
  }
}

function fault() {
  return process.env.STATE_RELOCATION_FAULT || "";
}

// copyFile(src, dst, ctx, rel) — ctx = { copied, rewrite, snap, dst }: snap holds each
// source's {size, mtimeMs}, dst the copy's.
// The snapshot is the source's stat taken before the read, so a write racing the read
// shows up as a later mtime and is re-copied by the reconcile.
function copyFile(src, dst, ctx, rel) {
  const st = fs.statSync(src);
  const buf = fs.readFileSync(src);
  if (fault() === "copy" && ctx.copied > 0) throw new RelocationError("copy");
  if (fault() === "rewrite") throw new RelocationError("rewrite");
  const out = rewriteBuffer(buf, ctx.rewrite);
  if (out && src.endsWith(".json") && !out.equals(buf)) {
    let wasValid = true;
    try { JSON.parse(buf.toString("utf8")); } catch (_) { wasValid = false; }
    if (wasValid) {
      try { JSON.parse(out.toString("utf8")); } catch (e) { throw new RelocationError("rewrite", e); }
    }
  }
  fs.writeFileSync(dst, out || buf);
  ctx.copied += 1;
  if (rel === undefined) return;
  ctx.snap.set(rel, { size: st.size, mtimeMs: st.mtimeMs });
  // What the mover itself wrote: a rename keeps it, so a later mismatch is another writer's.
  const ds = fs.statSync(dst);
  if (ctx.dst) ctx.dst.set(rel, { size: ds.size, mtimeMs: ds.mtimeMs });
}

// copyTree(src, dst, ctx, rel) — rel is the entry's path relative to the legacy root.
function copyTree(src, dst, ctx, rel) {
  const st = fs.lstatSync(src);
  if (st.isDirectory()) {
    fs.mkdirSync(dst);
    ctx.snap.set(rel, { dir: true });
    for (const n of fs.readdirSync(src)) {
      if (!LOCKISH_RE.test(n)) copyTree(path.join(src, n), path.join(dst, n), ctx, path.join(rel, n));
    }
  } else if (st.isFile()) {
    copyFile(src, dst, ctx, rel);
  } else {
    throw new RelocationError("copy", new Error(`unsupported entry type: ${src}`));
  }
}

module.exports = { LOCKISH_RE, RelocationError, fault, copyFile, copyTree };
