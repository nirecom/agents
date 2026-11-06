"use strict";
// Per-path integration rules (#2658). Each rule adds the path's M entry to out.delta (null removes
// it) and queues the working-tree writes in out.ops; nothing here writes a ref or the working tree.
// Each whole-file op carries `pre`, the target's stat at classification, for applyOps to recheck.

const fs = require("node:fs");
const path = require("node:path");
const G = require("./git");
const { union } = require("./jsonl");
const { decide, siblingName } = require("./conflict");
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

function localOf(c, rel) {
  const lE = c.lMap.get(rel);
  const w = c.w.get(rel);
  const blob = w ? (w.kind === "del" ? null : w.blob) : (lE ? lE.blob : null);
  const mode = w && w.mode ? w.mode : (lE ? lE.mode : "100644");
  return { lE, w, blob, mode };
}

// jsonlBoth — union of the working-tree transcript and the remote one; W only ever grows by the
// remote-only lines, except that leftover conflict markers force one full rewrite.
function jsonlBoth(c, rel, loc, rBlob, out) {
  const u = union(c.wText(rel) || "", c.blobText(rBlob));
  tally(c, u);
  if (u.deferred) {
    out.delta.set(rel, { mode: loc.mode, blob: rBlob });
    return;
  }
  out.delta.set(rel, { mode: loc.mode, blob: c.blobFor(u.text, [rBlob, loc.blob]) });
  if (u.droppedMarkerLines > 0) out.ops.push({ rel, kind: "text", text: u.text, mtime: true });
  else if (u.appendText) out.ops.push({ rel, kind: "append", text: u.appendText, mtime: true });
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
    const taken = (r) => out.delta.has(r) || c.lMap.has(r) || fs.existsSync(c.abs(r));
    const copy = siblingName(rel, c.host, c.now, taken);
    out.delta.set(copy, { mode: loc.mode, blob: loc.blob });
    out.ops.push({ rel: copy, kind: "blob", blob: loc.blob });
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
    if (!loc.w || loc.w.kind === "del") return;
    if (!jsonl || !loc.lE) {
      out.delta.set(rel, { mode: loc.mode, blob: loc.blob });
      return;
    }
    const u = union(c.wText(rel) || "", c.blobText(loc.lE.blob));
    tally(c, u);
    if (u.deferred) return;
    out.delta.set(rel, { mode: loc.mode, blob: c.blobFor(u.text, [loc.lE.blob, loc.blob]) });
    if (u.droppedMarkerLines > 0) out.ops.push({ rel, kind: "text", text: u.text });
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
    const u = union(c.wText(rel) || "", c.blobText(r.newBlob));
    tally(c, u);
    if (u.deferred) return;
    if (u.droppedMarkerLines > 0) out.ops.push({ rel, kind: "text", text: u.text, mtime: true });
    else if (u.appendText) out.ops.push({ rel, kind: "append", text: u.appendText, mtime: true });
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

// classify(base) -> {delta, ops}. base: {mode: "sync"|"reset", dir, host, now, R, lMap, w,
// rDiff, lDiff, rMap, stats}. Excluded paths leave M; special paths are handled by the caller.
function classify(base) {
  const c = makeCtx(base);
  const out = { delta: new Map(), ops: [] };
  const rels = new Set([...c.w.keys(), ...c.lMap.keys()]);
  for (const rel of (c.mode === "reset" ? c.rMap : c.rDiff).keys()) rels.add(rel);
  for (const rel of rels) {
    if (SPECIAL.has(rel)) continue;
    if (isExcluded(rel)) {
      if (c.lMap.has(rel) || (c.rMap && c.rMap.has(rel))) out.delta.set(rel, null);
      continue;
    }
    if (c.mode === "reset") resetPath(c, rel, out);
    else if (c.w.has(rel) || c.rDiff.has(rel)) syncPath(c, rel, out);
  }
  for (const op of out.ops) {
    if (op.kind !== "append") op.pre = c.w.has(op.rel) ? c.w.get(op.rel).sig : statSig(c.abs(op.rel));
  }
  return { out, ctx: c };
}

module.exports = { REGULAR, SPECIAL, classify, makeCtx };
