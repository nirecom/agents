"use strict";
// Per-path integration rules (#2658). Each rule adds the path's M entry to out.delta (null removes
// it) and queues the working-tree writes in out.ops; nothing here writes a ref or the working tree.
// Each op carries `pre`, the target's stat at classification, for applyOps to recheck.

const fs = require("node:fs");
const path = require("node:path");
const G = require("./git");
const { union, joinLines } = require("./jsonl");
const { decide, siblingName, collisionCopyName } = require("./conflict");
const { isExcluded } = require("./exclude");
const { statSig } = require("./apply");

const REGULAR = new Set(["100644", "100755"]);
const SPECIAL = new Set([".gitignore", ".gitattributes", ".history.jsonl"]);

function makeCtx(base) {
  const abs = (rel) => path.join(base.dir, ...rel.split("/"));
  return Object.assign({
    abs,
    wText: (rel) => { try { return fs.readFileSync(abs(rel), "utf8"); } catch (_) { return null; } },
    wMtime: (rel) => { try { return fs.statSync(abs(rel)).mtimeMs; } catch (_) { return 0; } },
    blobText: (blob) => G.catBlob(base.dir, blob).toString("utf8"),
    blobFor: (text, known) => {
      const id = G.blobIdOf(Buffer.from(text, "utf8"));
      return known.includes(id) ? id : G.hashText(base.dir, text);
    },
  }, base);
}

function tally(c, u) {
  c.stats.uuidMismatch += u.uuidMismatch;
  c.stats.droppedMarkerLines += u.droppedMarkerLines;
}

// addSibling — keeps the local content that lost a both-changed conflict as a new conflict copy
// next to rel, in M and in W, and returns the copy's path.
function addSibling(c, out, rel, mode, blob) {
  const inRemote = (r) => (c.rMap && c.rMap.has(r)) || (c.rDiff && c.rDiff.has(r));
  const inLocalDiff = (r) => c.lDiff && c.lDiff.has(r);
  const taken = (r) => out.delta.has(r) || c.lMap.has(r) || inRemote(r) || inLocalDiff(r) || fs.existsSync(c.abs(r));
  const copy = siblingName(rel, c.host, c.now, taken);
  out.delta.set(copy, { mode, blob });
  out.ops.push({ rel: copy, kind: "blob", blob });
  return copy;
}

// queueJsonl — makes W hold u.text, the transcript M records: an append when W + appendText already
// equals it, else a full rewrite (dropped markers, a replaced local line, or the remote line order).
function queueJsonl(out, rel, wText, u, flags = {}) {
  if (wText + u.appendText !== u.text) out.ops.push(Object.assign({ rel, kind: "text", text: u.text }, flags));
  else if (u.appendText) out.ops.push(Object.assign({ rel, kind: "append", text: u.appendText }, flags));
}

function localOf(c, rel) {
  const lE = c.lMap.get(rel);
  const w = c.w.get(rel);
  const blob = w ? (w.kind === "del" ? null : w.blob) : (lE ? lE.blob : null);
  const mode = w && w.mode ? w.mode : (lE ? lE.mode : "100644");
  return { lE, w, blob, mode };
}

// jsonlBoth — union of the working-tree transcript and the remote one; W and M hold the same text.
// Lines the union drops from either side (a lost same-uuid conflict, a duplicate) go to a conflict
// copy, since both sides changed and neither is known to be the newer edit. Keeping the remote side's
// too means the copy exists whichever machine pushed first: the other one only sees W unchanged.
function jsonlBoth(c, rel, loc, rBlob, out) {
  const wText = c.wText(rel) || "";
  const u = union(wText, c.blobText(rBlob));
  tally(c, u);
  if (u.deferred) {
    out.delta.set(rel, { mode: loc.mode, blob: rBlob });
    return;
  }
  out.delta.set(rel, { mode: loc.mode, blob: c.blobFor(u.text, [rBlob, loc.blob]) });
  queueJsonl(out, rel, wText, u, { mtime: true });
  const lost = [...new Set(u.lostLocal.concat(u.lostRemote))];
  if (lost.length === 0) return;
  const copy = addSibling(c, out, rel, loc.mode, c.blobFor(joinLines(lost), []));
  c.stats.conflicts.push({ path: rel, copy, localMtime: null, remoteTime: null, lostLines: lost.length });
}

function fileBoth(c, rel, loc, rE, out) {
  const localMtime = c.wMtime(rel);
  const remoteTime = G.remoteTimeMs(c.dir, c.R, rel);
  const choice = decide({ localMtimeMs: localMtime, remoteTimeMs: remoteTime });
  if (choice === "local") {
    out.delta.set(rel, { mode: loc.mode, blob: loc.blob });
    return;
  }
  out.delta.set(rel, rE);
  if (choice === "both") {
    const copy = addSibling(c, out, rel, loc.mode, loc.blob);
    c.stats.conflicts.push({
      path: rel, copy, localMtime: new Date(localMtime).toISOString(), remoteTime: new Date(remoteTime).toISOString(),
    });
  }
  out.ops.push({ rel, kind: "blob", blob: rE.blob });
}

function both(c, rel, loc, rE, out) {
  if (rel.endsWith(".jsonl")) jsonlBoth(c, rel, loc, rE.blob, out);
  else fileBoth(c, rel, loc, rE, out);
}

// syncPath — push / pull. The local side is read against B = merge-base(L, R), so a commit only
// on local main is never mistaken for a remote deletion.
function syncPath(c, rel, out) {
  const loc = localOf(c, rel);
  const r = c.rDiff.get(rel);
  const jsonl = rel.endsWith(".jsonl");
  if (!r) {
    // M starts from L's tree, so a path only L deleted goes back in or the push deletes it from R; W stays without it.
    const lChange = c.lDiff.get(rel);
    if (loc.blob === null && lChange && !lChange.newBlob) {
      out.delta.set(rel, { mode: lChange.oldMode, blob: lChange.oldBlob });
      return;
    }
    if (!loc.w || loc.w.kind === "del") return;
    if (!jsonl || !loc.lE) {
      out.delta.set(rel, { mode: loc.mode, blob: loc.blob });
      return;
    }
    const wText = c.wText(rel) || "";
    const u = union(wText, c.blobText(loc.lE.blob), { prefer: "local" });
    tally(c, u);
    if (u.deferred) return;
    out.delta.set(rel, { mode: loc.mode, blob: c.blobFor(u.text, [loc.lE.blob, loc.blob]) });
    queueJsonl(out, rel, wText, u);
    return;
  }
  const bBlob = c.lDiff.has(rel) ? c.lDiff.get(rel).oldBlob : (loc.lE ? loc.lE.blob : null);
  if (!r.newBlob) {
    out.delta.set(rel, loc.blob === null || loc.blob === bBlob ? null : { mode: loc.mode, blob: loc.blob });
    return;
  }
  const rE = { mode: r.mode, blob: r.newBlob };
  if (!REGULAR.has(r.mode)) {
    out.delta.set(rel, rE);
    return;
  }
  if (loc.blob === null) {
    out.delta.set(rel, rE);
    const lBlob = loc.lE ? loc.lE.blob : null;
    if (!(loc.w && loc.w.kind === "del" && r.newBlob === lBlob)) out.ops.push({ rel, kind: "blob", blob: r.newBlob, mtime: jsonl });
    return;
  }
  if (loc.blob === r.newBlob) {
    out.delta.set(rel, rE);
    return;
  }
  if (loc.blob === bBlob) {
    out.delta.set(rel, rE);
    if (!jsonl) {
      out.ops.push({ rel, kind: "blob", blob: r.newBlob });
      return;
    }
    // W is unchanged since B, so the remote line is the newer edit on every same-uuid conflict.
    const wText = c.wText(rel) || "";
    const u = union(wText, c.blobText(r.newBlob), { prefer: "remote" });
    tally(c, u);
    if (u.deferred) return;
    out.delta.set(rel, { mode: r.mode, blob: c.blobFor(u.text, [r.newBlob, loc.blob]) });
    queueJsonl(out, rel, wText, u, { mtime: true });
    return;
  }
  both(c, rel, loc, rE, out);
}

// resetPath — reset. M starts from R's tree; local-only files are added, differing ones merged.
function resetPath(c, rel, out) {
  const loc = localOf(c, rel);
  const rE = c.rMap.get(rel);
  if (!rE) {
    if (loc.blob !== null) out.delta.set(rel, { mode: loc.mode, blob: loc.blob });
    return;
  }
  if (!REGULAR.has(rE.mode) || loc.blob === rE.blob) return;
  if (loc.blob === null) {
    out.ops.push({ rel, kind: "blob", blob: rE.blob });
    return;
  }
  both(c, rel, loc, rE, out);
}

// resolvePathCollisions — M cannot hold both a file and a directory at one path, and writeTree would
// silently drop one side. The directory side stays; the file moves to a copy named from its blob.
// A copy slot already holding other content, deleted this round, or a directory in the final tree is
// never used: the file takes the first free numbered name instead, so its blob never leaves M unrecorded.
// A numbered slot already holding the same blob is reused, so repeated syncs converge on one copy.
// suffixedSlot returns that slot's name, or null when the delta already holds the same blob there.
function suffixedSlot(c, out, base, ancestors, f, e) {
  for (let n = 2; ; n++) {
    const r = collisionCopyName(f, e.blob, n);
    const d = out.delta.get(r);
    if (d && d.blob === e.blob) return null;
    const held = base.get(r);
    if (!out.delta.has(r) && held && held.blob === e.blob && !ancestors.has(r)) return r;
    if (!out.delta.has(r) && !base.has(r) && !ancestors.has(r) && !fs.existsSync(c.abs(r))) return r;
  }
}

function resolvePathCollisions(c, out) {
  const base = c.mode === "reset" ? c.rMap : c.lMap;
  const paths = new Set(base.keys());
  for (const [rel, e] of out.delta) {
    if (e) paths.add(rel);
    else paths.delete(rel);
  }
  const ancestors = new Set();
  for (const rel of paths) {
    for (let i = rel.indexOf("/"); i >= 0; i = rel.indexOf("/", i + 1)) ancestors.add(rel.slice(0, i));
  }
  for (const f of paths) {
    if (!ancestors.has(f) || SPECIAL.has(f)) continue;
    const e = out.delta.get(f) || base.get(f);
    out.delta.set(f, null);
    out.ops = out.ops.filter((op) => op.rel !== f);
    const plain = collisionCopyName(f, e.blob);
    const d = out.delta.get(plain);
    if (d && d.blob === e.blob) continue;
    const held = base.get(plain);
    let copy = plain;
    if (out.delta.has(plain) || (held && held.blob !== e.blob) || ancestors.has(plain)) {
      copy = suffixedSlot(c, out, base, ancestors, f, e);
      if (copy === null) continue;
    }
    out.delta.set(copy, { mode: e.mode, blob: e.blob });
    if (REGULAR.has(e.mode) && !fs.existsSync(c.abs(copy))) out.ops.push({ rel: copy, kind: "blob", blob: e.blob });
    const kept = base.get(copy);
    if (!kept || kept.blob !== e.blob) c.stats.conflicts.push({ path: f, copy, localMtime: null, remoteTime: null });
  }
}

// classify(base) -> {delta, ops}. base: {mode: "sync"|"reset", dir, host, now, R, lMap, w,
// rDiff, lDiff, rMap, stats}. Excluded paths leave M; special paths are handled by the caller.
function classify(base) {
  const c = makeCtx(base);
  const out = { delta: new Map(), ops: [] };
  const rels = new Set([...c.w.keys(), ...c.lMap.keys()]);
  for (const rel of (c.mode === "reset" ? c.rMap : c.rDiff).keys()) rels.add(rel);
  if (c.mode !== "reset") {
    for (const [rel, d] of c.lDiff) if (!d.newBlob) rels.add(rel);
  }
  for (const rel of rels) {
    if (SPECIAL.has(rel)) continue;
    if (isExcluded(rel)) {
      if (c.lMap.has(rel) || (c.rMap && c.rMap.has(rel))) out.delta.set(rel, null);
      continue;
    }
    if (c.mode === "reset") resetPath(c, rel, out);
    else if (!c.lMap.has(rel) || c.w.has(rel) || c.rDiff.has(rel)) syncPath(c, rel, out);
  }
  resolvePathCollisions(c, out);
  for (const op of out.ops) {
    op.pre = c.w.has(op.rel) ? c.w.get(op.rel).sig : statSig(c.abs(op.rel));
  }
  return { out, ctx: c };
}

module.exports = { REGULAR, SPECIAL, classify, makeCtx };
