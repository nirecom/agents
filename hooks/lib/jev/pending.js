"use strict";
// hooks/lib/jev/pending.js — the pre -> post hand-off, keyed by tool_use_id.
// <jevStateDir>/<sid>/pending/<tid>.json is written atomically by the pre hook and
// claimed by the post hook with a rename to <tid>.claimed-<pid> (so a duplicate or late
// post finds nothing and records "not-run" instead of a second pairing); the claimed file
// is released only after the record is logged. A pending or claim that outlives its TTL
// is an orphan: handed to onOrphan as "llm missing", then removed once that is logged; the
// sweep takes each orphan under its own <tid>.claimed-<sweep id>-sweep name.
// A post with no claim whose append failed leaves <tid>.unlogged-<pid>-<ts> for the sweep.
// A pending or unlogged write retries once when retention renames the session dir away mid-write.

const fs = require("fs");
const path = require("path");
const { isValidId, sessionDir } = require("./state-paths");

const DEFAULT_PENDING_TTL_MS = 3600000;
const CLAIMED_MARK = ".claimed-";
const UNLOGGED_MARK = ".unlogged-";
// Suffix after the last mark: <pid>[-sweep] or <sweep id>-sweep for a claim, <pid>-<ts> for an unlogged record.
const MARK_SUFFIX_RE = { [CLAIMED_MARK]: /^\d+(-sweep)?$/, [UNLOGGED_MARK]: /^\d+-\d+$/ };
let sweepSeq = 0;

function pendingDir(sid) {
  return path.join(sessionDir(sid), "pending");
}

// mkdir + tmp write + rename into the session's pending dir. Retention may rename the session
// dir to a tombstone between the mkdir and the rename, so an ENOENT is retried exactly once.
function writeEntryAtomic(sid, tmpName, finalName, obj) {
  for (let attempt = 0; ; attempt++) {
    const dir = pendingDir(sid);
    const tmp = path.join(dir, tmpName);
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(tmp, JSON.stringify(obj));
      fs.renameSync(tmp, path.join(dir, finalName));
      return;
    } catch (e) {
      removeQuietly(tmp);
      if (attempt > 0 || !e || e.code !== "ENOENT") throw e;
    }
  }
}

function writePending(sid, tid, obj) {
  if (!isValidId(tid)) throw new Error("invalid tool_use_id");
  writeEntryAtomic(sid, `${tid}.${process.pid}.tmp`, `${tid}.json`, obj);
}

function touch(p, ms) {
  try {
    const t = ms / 1000;
    fs.utimesSync(p, t, t);
  } catch (_e) { /* the previous mtime still bounds the TTL */ }
}

// Rename to a name only this process owns, restart its TTL at once (so a concurrent sweep
// never takes a claim being read or logged), then read it. The renamed file is kept: the
// caller removes it only once the judgment is logged, so a kill in between leaves an
// orphan for sweepOrphans instead of a lost record.
function takeByRename(src, dst, touchMs) {
  try {
    fs.renameSync(src, dst);
  } catch (_e) {
    return { taken: false, obj: null };
  }
  touch(dst, touchMs);
  let obj = null;
  try {
    obj = JSON.parse(fs.readFileSync(dst, "utf8"));
  } catch (_e) {
    obj = null;
  }
  return { taken: true, obj };
}

function removeQuietly(p) {
  try { fs.unlinkSync(p); } catch (_e) { /* already removed */ }
}

function claimedPath(sid, tid) {
  return path.join(pendingDir(sid), `${tid}${CLAIMED_MARK}${process.pid}`);
}

// null when there is nothing to claim.
function claimPending(sid, tid) {
  if (!isValidId(tid)) return null;
  const dst = claimedPath(sid, tid);
  const r = takeByRename(path.join(pendingDir(sid), `${tid}.json`), dst, Date.now());
  if (!r.taken) return null;
  return r.obj || {};
}

// Call only after the decision record is appended.
function releaseClaim(sid, tid) {
  if (!isValidId(tid)) return;
  removeQuietly(claimedPath(sid, tid));
}

// Atomically replaces this process's claim with obj, so a failed append leaves what was
// observed for the orphan sweep. False (never a throw) when the claim could not be rewritten.
function rewriteClaim(sid, tid, obj) {
  let tmp = null;
  try {
    if (!isValidId(tid)) return false;
    tmp = path.join(pendingDir(sid), `${tid}.${process.pid}.claim.tmp`);
    fs.writeFileSync(tmp, JSON.stringify(obj));
    fs.renameSync(tmp, claimedPath(sid, tid));
    return true;
  } catch (_e) {
    if (tmp) removeQuietly(tmp);
    return false;
  }
}

// Leaves obj (a claim-shaped hand-off) for a later sweep to append. False on any failure.
function writeUnlogged(sid, tid, obj) {
  try {
    if (!isValidId(tid)) return false;
    writeEntryAtomic(sid, `${tid}.${process.pid}.unlogged.tmp`, `${tid}${UNLOGGED_MARK}${process.pid}-${Date.now()}`, obj);
    return true;
  } catch (_e) {
    return false;
  }
}

function appendFailed(result) {
  return Boolean(result) && typeof result === "object" && result.ok === false;
}

// The mark that ends name (searched from the right, so a tid may itself contain a mark).
function markOf(name) {
  let best = null;
  for (const mark of [CLAIMED_MARK, UNLOGGED_MARK]) {
    const i = name.lastIndexOf(mark);
    if (i > 0 && (!best || i > best.i)) best = { mark, i };
  }
  if (!best || !MARK_SUFFIX_RE[best.mark].test(name.slice(best.i + best.mark.length))) return null;
  return best;
}

function tidOf(name) {
  if (name.endsWith(".json")) return name.slice(0, -".json".length);
  const m = markOf(name);
  return m ? name.slice(0, m.i) : null;
}

// Digits only, so the name keeps the <digits>-sweep claim shape: fixed-width pid and clock,
// then a per-process counter, so no two takes (in this process or any other) share a name.
function sweepClaimId(now) {
  const ms = Number.isFinite(now) ? Math.max(0, Math.trunc(now)) : 0;
  return `${String(process.pid).padStart(10, "0")}${String(ms).padStart(16, "0")}${sweepSeq++}`;
}

// sweepOrphans(sid, {now, ttlMs, minClaimAgeMs, onOrphan, skipTid}): TTL-expired .json,
// .claimed-* and .unlogged-* entries go to onOrphan(tid, obj); the entry is removed unless
// onOrphan throws or returns {ok:false}, so a failed append is retried by a later sweep.
// An unparseable entry reaches onOrphan as {} (as claimPending does), so it is still recorded.
// A claim younger than minClaimAgeMs is skipped: a post or another sweeper is handling it.
// Each taken entry gets its own <tid>.claimed-<sweep id>-sweep name (sweepClaimId), so a kept
// claim is never overwritten by the next entry of the same tid. TTL-expired .tmp files are deleted.
function sweepOrphans(sid, opts = {}) {
  const now = opts.now ? opts.now() : Date.now();
  const ttl = Number.isFinite(opts.ttlMs) && opts.ttlMs >= 0 ? opts.ttlMs : DEFAULT_PENDING_TTL_MS;
  const minClaimAge = Number.isFinite(opts.minClaimAgeMs) && opts.minClaimAgeMs >= 0 ? opts.minClaimAgeMs : 0;
  let dir;
  let names;
  try {
    dir = pendingDir(sid);
    names = fs.readdirSync(dir);
  } catch (_e) {
    return 0;
  }
  let swept = 0;
  for (const name of names) {
    const p = path.join(dir, name);
    let st;
    try { st = fs.lstatSync(p); } catch (_e) { continue; }
    if (!st.isFile() || now - st.mtimeMs <= ttl) continue;
    if (name.endsWith(".tmp")) {
      try { fs.unlinkSync(p); } catch (_e) { /* raced */ }
      continue;
    }
    const tid = tidOf(name);
    if (!tid || !isValidId(tid) || tid === opts.skipTid) continue;
    const m = name.endsWith(".json") ? null : markOf(name);
    if (m && m.mark === CLAIMED_MARK && now - st.mtimeMs <= minClaimAge) continue;
    const dst = path.join(dir, `${tid}${CLAIMED_MARK}${sweepClaimId(now)}-sweep`);
    const r = takeByRename(p, dst, now);
    if (!r.taken) continue;
    swept++;
    let logged = true;
    if (typeof opts.onOrphan === "function") {
      try {
        logged = !appendFailed(opts.onOrphan(tid, r.obj || {}));
      } catch (_e) {
        logged = false; // one orphan never blocks the rest
      }
    }
    if (logged) removeQuietly(dst);
  }
  return swept;
}

// True while the session still holds a pending, claimed, -sweep or unlogged entry. Only a
// missing dir is false: any other read error keeps the dir (conservative).
// hasEntriesIn(dir): the same test for any session-shaped dir (a live one or a retention tombstone).
function hasEntriesIn(dir) {
  let names;
  try {
    names = fs.readdirSync(path.join(dir, "pending"));
  } catch (e) {
    return !(e && e.code === "ENOENT");
  }
  return names.some((n) => !n.endsWith(".tmp") && isValidId(tidOf(n)));
}

function hasEntries(sid) {
  return hasEntriesIn(sessionDir(sid));
}

module.exports = {
  DEFAULT_PENDING_TTL_MS, pendingDir, writePending, claimPending, releaseClaim, rewriteClaim, writeUnlogged,
  sweepOrphans, hasEntries, hasEntriesIn,
};
