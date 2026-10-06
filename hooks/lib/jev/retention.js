"use strict";
// hooks/lib/jev/retention.js — keeps per-session Jev state from piling up forever.
// At most once per 24 h (throttled by the mtime of <jevStateDir>/.last-retention-sweep),
// session dirs whose newest mtime is older than 7 days are removed. Their orphan pending
// entries are first handed to onOrphan, and a dir that still holds an unlogged one is
// kept, so no dispatch disappears without a record. A claim younger than the pending TTL
// is left to its owner. Removal goes through a tombstone (.tomb-<sid>-<digits>) that is
// re-checked: one that gained entries is restored or merged back and the sid is not
// reported removed. A leftover tombstone (a killed sweep's) holding entries is restored or
// merged back the same way, for the next due sweep to handle; a stale entry-free one is
// removed. Floor: cleanupZombies.

const fs = require("fs");
const path = require("path");
const { isValidId, jevStateDir } = require("./state-paths");
const { DEFAULT_PENDING_TTL_MS, sweepOrphans, hasEntries, hasEntriesIn } = require("./pending");

const TOMB_PREFIX = ".tomb-";
let tombSeq = 0;
const DAY_MS = 86400000;
const SWEEP_INTERVAL_MS = DAY_MS;
const DEFAULT_MAX_AGE_DAYS = 7;
const MARKER_NAME = ".last-retention-sweep";

// Newest mtime anywhere under p; symlinks are stat'ed, never followed. filesOnly ignores
// directory mtimes, which the sweep's own renames and unlinks have just refreshed.
function newestMtime(p, filesOnly = false) {
  let st;
  try { st = fs.lstatSync(p); } catch (_e) { return 0; }
  if (!st.isDirectory()) return st.mtimeMs;
  let newest = filesOnly ? 0 : st.mtimeMs;
  let names = [];
  try { names = fs.readdirSync(p); } catch (_e) { names = []; }
  for (const n of names) newest = Math.max(newest, newestMtime(path.join(p, n), filesOnly));
  return newest;
}

// Claims the day's sweep by refreshing the marker; false when not yet due.
function claimSweep(root, now) {
  const marker = path.join(root, MARKER_NAME);
  try {
    const st = fs.statSync(marker);
    if (now - st.mtimeMs < SWEEP_INTERVAL_MS) return false;
  } catch (_e) { /* no marker yet: due */ }
  try {
    fs.mkdirSync(root, { recursive: true });
    fs.writeFileSync(marker, "");
    const t = now / 1000;
    fs.utimesSync(marker, t, t);
  } catch (_e) {
    return false;
  }
  return true;
}

// Digits only (pid, clock, per-process counter), so no two tombstones share a name.
function tombName(sid, now) {
  return `${TOMB_PREFIX}${sid}-${process.pid}${Math.max(0, Math.trunc(now))}${tombSeq++}`;
}

// Puts a tombstone that received late writes back: whole when the original path is still
// free, else its files are moved into the recreated dir, never overwriting a same-name file.
// The tombstone is removed only once nothing is left in it.
function restoreTombstone(dir, tomb, now, maxAgeMs) {
  try {
    if (!fs.existsSync(dir)) {
      fs.renameSync(tomb, dir);
      return;
    }
    const from = path.join(tomb, "pending");
    const to = path.join(dir, "pending");
    fs.mkdirSync(to, { recursive: true });
    for (const n of fs.readdirSync(from)) {
      const dst = path.join(to, n);
      if (!fs.existsSync(dst)) fs.renameSync(path.join(from, n), dst);
    }
  } catch (_e) { /* the tombstone is kept; a later sweep retries */ }
  try {
    if (!hasEntriesIn(tomb) && now - newestMtime(tomb, true) > maxAgeMs) fs.rmSync(tomb, { recursive: true, force: true });
  } catch (_e) { /* kept */ }
}

// The sid of a .tomb-<sid>-<digits> name (up to the last -<digits>), or null when invalid.
function tombSid(name) {
  const m = /^\.tomb-(.+)-\d+$/.exec(name);
  return m && isValidId(m[1]) ? m[1] : null;
}

// A tombstone a killed sweep left behind: one holding pending entries is restored to its
// sid (a tomb whose name yields no valid sid is left alone); else removed once stale.
function cleanLeftoverTombstones(root, names, now, maxAgeMs) {
  for (const n of names) {
    if (!n.startsWith(TOMB_PREFIX)) continue;
    const p = path.join(root, n);
    try {
      if (!fs.lstatSync(p).isDirectory()) continue;
      if (hasEntriesIn(p)) {
        const sid = tombSid(n);
        if (sid) restoreTombstone(path.join(root, sid), p, now, maxAgeMs);
      } else if (now - newestMtime(p) > maxAgeMs) {
        fs.rmSync(p, { recursive: true, force: true });
      }
    } catch (_e) { /* kept */ }
  }
}

// sweepStateDirs({now, maxAgeDays, onOrphan(sid, tid, obj), beforeRemove(sid, tombDir)}): returns removed sids.
function sweepStateDirs(opts = {}) {
  const now = opts.now ? opts.now() : Date.now();
  const maxAgeMs = (opts.maxAgeDays || DEFAULT_MAX_AGE_DAYS) * DAY_MS;
  const root = jevStateDir();
  if (!claimSweep(root, now)) return [];
  let names = [];
  try { names = fs.readdirSync(root); } catch (_e) { return []; }
  const removed = [];
  cleanLeftoverTombstones(root, names, now, maxAgeMs);
  for (const sid of names) {
    if (!isValidId(sid) || sid.startsWith(TOMB_PREFIX)) continue;
    const dir = path.join(root, sid);
    let st;
    try { st = fs.lstatSync(dir); } catch (_e) { continue; }
    if (!st.isDirectory() || now - newestMtime(dir) <= maxAgeMs) continue;
    // onOrphan's result and exceptions reach sweepOrphans, which keeps an unlogged claim.
    sweepOrphans(sid, {
      now: () => now,
      ttlMs: 0,
      minClaimAgeMs: DEFAULT_PENDING_TTL_MS,
      onOrphan: (tid, obj) => (typeof opts.onOrphan === "function" ? opts.onOrphan(sid, tid, obj) : undefined),
    });
    // Re-checked just before the rename: a hook may have written into the dir meanwhile.
    if (hasEntries(sid) || now - newestMtime(dir, true) <= maxAgeMs) continue;
    const tomb = path.join(root, tombName(sid, now));
    try {
      fs.renameSync(dir, tomb);
    } catch (_e) {
      continue; // retried on the next due sweep
    }
    if (typeof opts.beforeRemove === "function") {
      try { opts.beforeRemove(sid, tomb); } catch (_e) { /* test hook only */ }
    }
    // A writer that held the old path open may have landed in the tombstone.
    if (hasEntriesIn(tomb) || now - newestMtime(tomb, true) <= maxAgeMs) {
      restoreTombstone(dir, tomb, now, maxAgeMs);
      continue;
    }
    try {
      fs.rmSync(tomb, { recursive: true, force: true });
      if (!fs.existsSync(dir)) removed.push(sid); // else a hook already recreated the session
    } catch (_e) { /* the leftover tombstone is cleaned by a later sweep */ }
  }
  return removed;
}

module.exports = { SWEEP_INTERVAL_MS, DEFAULT_MAX_AGE_DAYS, MARKER_NAME, sweepStateDirs, newestMtime };
