"use strict";
// Temporary (#2511): deleted with this folder per the deletion-condition in state-root.js
// Brings a copy up to date with the legacy session it was taken from, under the legacy locks.
// A legacy write that landed after the copy (an unlocked marker writer, or a writer that
// resolved its path before the move) would otherwise be lost with the legacy delete.
// move.js runs it twice: into the private work dir before the commit, then once more
// into the new root after it, where a destination another writer has touched since the
// mover wrote it is left alone (that writer's content is the newer one).
const fs = require("fs");
const path = require("path");
const { LOCKISH_RE, fault, copyFile } = require("./copy");
const { isSidEntry, isOffClearanceEntry } = require("./legacy");

// The mover holds this lock dir inside the legacy control dir until it returns.
const HELD_SUPERVISOR_LOCK = "supervisor-state.json.lock";

function readNames(dir) {
  try {
    return fs.readdirSync(dir);
  } catch (_) {
    return [];
  }
}

function rmQuiet(p) {
  try {
    fs.rmSync(p, { recursive: true, force: true });
  } catch (_) { /* best-effort; leftovers are counted from what still exists */ }
}

// Only a missing path means "gone": any other stat error (EPERM, EBUSY on Windows) throws,
// so the caller keeps the entry instead of reading the failure as a deletion.
function lstatOrNull(p) {
  try {
    if (fault() === "lstat" && p.includes(".control")) {
      throw Object.assign(new Error("injected lstat fault"), { code: "EPERM" });
    }
    return fs.lstatSync(p);
  } catch (e) {
    if (e && (e.code === "ENOENT" || e.code === "ENOTDIR")) return null;
    throw e;
  }
}

// The OFF-clearance family is dropped, not migrated: unlocked consumers could spend the
// legacy token after the commit and leave its new-root copy as a second grant.
function isMigratedEntry(name, sid) {
  return isSidEntry(name, sid) && !LOCKISH_RE.test(name) && !isOffClearanceEntry(name, sid);
}

function changedSince(snap, rel, st) {
  const s = snap.get(rel);
  return !s || Boolean(s.dir) || s.size !== st.size || s.mtimeMs !== st.mtimeMs;
}

// The destination is still the mover's own: never written and absent, or exactly as written.
// A small check-then-write window remains against an unlocked writer (markers are tmp+rename).
// A destination that cannot be stat'd throws: "not ours" would skip the re-copy and still
// let the legacy delete take the newer content, so the caller keeps the entry instead.
function untouched(ctx, rel, dst) {
  const prev = ctx.dst.get(rel);
  const cur = lstatOrNull(dst);
  if (!prev) return cur === null;
  return cur !== null && cur.isFile() && cur.size === prev.size && cur.mtimeMs === prev.mtimeMs;
}

// Entries that vanished from legacy: files first (deepest first), then their dirs by rmdir,
// so anything another writer put there keeps its dir.
function dropVanished(seen, dstRoot, ctx) {
  const gone = [...ctx.snap.keys()].filter((rel) => !seen.has(rel));
  gone.sort((a, b) => b.length - a.length);
  for (const rel of gone) {
    const dst = path.join(dstRoot, rel);
    if (ctx.snap.get(rel).dir) {
      try { fs.rmdirSync(dst); } catch (_) { /* not empty or already gone */ }
    } else {
      try {
        if (untouched(ctx, rel, dst)) rmQuiet(dst);
      } catch (_) { /* cannot tell whose it is: leave it */ }
    }
    ctx.snap.delete(rel);
    ctx.dst.delete(rel);
  }
}

// reconcile(sid, names, r, ctx, dstRoot) -> { names, kept }
// names: the top-level legacy entries now safe to delete (the copied ones plus any that
// appeared since); kept: entries whose re-copy failed, left in legacy so their newer
// content is not deleted. Before the commit move.js aborts on any; after it they count
// as leftovers.
function reconcile(sid, names, r, ctx, dstRoot) {
  const late = readNames(r.legRoot).filter((n) => isMigratedEntry(n, sid));
  const top = [...new Set([...names, ...late])];
  const seen = new Set();
  const failed = new Set();
  const walk = (rel, owner) => {
    const src = path.join(r.legRoot, rel);
    const dst = path.join(dstRoot, rel);
    try {
      const st = lstatOrNull(src);
      if (st === null) return; // vanished from legacy: dropVanished handles it
      seen.add(rel);
      if (st.isDirectory()) {
        fs.mkdirSync(dst, { recursive: true });
        if (!ctx.snap.has(rel)) ctx.snap.set(rel, { dir: true });
        for (const n of fs.readdirSync(src)) {
          if (!LOCKISH_RE.test(n)) walk(path.join(rel, n), owner);
        }
      } else if (st.isFile()) {
        // Only the control dir fails, so the other entries reconcile cleanly: one kept entry alone must stop the commit.
        if (fault() === "reconcile" && owner === `${sid}.control`) throw new Error("injected reconcile fault");
        if (changedSince(ctx.snap, rel, st) && untouched(ctx, rel, dst)) {
          fs.mkdirSync(path.dirname(dst), { recursive: true });
          copyFile(src, dst, ctx, rel);
        }
      } else {
        failed.add(owner);
      }
    } catch (_) {
      // An unreadable entry is not a vanished one, and neither is anything under it.
      seen.add(rel);
      for (const k of ctx.snap.keys()) {
        if (k.startsWith(rel + path.sep)) seen.add(k);
      }
      failed.add(owner);
    }
  };
  for (const n of top) walk(n, n);
  dropVanished(seen, dstRoot, ctx);
  return { names: top.filter((n) => !failed.has(n)), kept: top.filter((n) => failed.has(n)) };
}

// Under the locks: everything but the held supervisor lock dir. The control dir that
// holds it is removed by finishLegacy once the locks are released. The uncopied
// OFF-clearance token and claim go too (a live mint's lock/tmp is left to zombie cleanup).
function deleteLegacy(sid, names, legRoot) {
  if (fault() === "old-delete") return;
  for (const n of readNames(legRoot)) {
    if (isOffClearanceEntry(n, sid) && !LOCKISH_RE.test(n)) rmQuiet(path.join(legRoot, n));
  }
  const ctl = `${sid}.control`;
  for (const n of names) {
    if (n !== ctl) {
      rmQuiet(path.join(legRoot, n));
      continue;
    }
    for (const c of readNames(path.join(legRoot, n))) {
      if (c !== HELD_SUPERVISOR_LOCK) rmQuiet(path.join(legRoot, n, c));
    }
  }
}

// After the locks: rmdir, never rm -r, so a lock another writer has taken in the
// control dir since is not pulled from under it (the dir then counts as a leftover).
function finishLegacy(sid, legRoot) {
  if (fault() === "old-delete") return;
  try {
    fs.rmdirSync(path.join(legRoot, `${sid}.control`));
  } catch (_) { /* not empty or already gone */ }
}

function countLeftovers(names, legRoot) {
  return names.filter((n) => fs.existsSync(path.join(legRoot, n))).length;
}

module.exports = { isMigratedEntry, reconcile, deleteLegacy, finishLegacy, countLeftovers };
