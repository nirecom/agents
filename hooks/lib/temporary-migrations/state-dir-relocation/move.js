"use strict";
// Temporary (#2511): deleted with this folder per the deletion-condition in state-root.js
// Moves one legacy session into the new state root at /session-close.
// The single commit point is the last rename, <new>/<sid>.json: before it the session
// still routes legacy and the legacy root stays authoritative, so any crash or failure
// leaves partial new-root entries that the next move sweeps (step 4).
// Both legacy session locks are held, workflow state first, from the sweep through the
// legacy delete, and their new-root twins from before the commit (moveLocked); only the
// emptied legacy control dir, which holds the supervisor lock, is removed after release.
// STATE_RELOCATION_FAULT=copy|rewrite|reconcile|lstat|control-rename|json-rename|rollback|old-delete
// reproduces each failure; control-rename and rollback crash the process.
const fs = require("fs");
const os = require("os");
const path = require("path");
const { getStateRoot, assertValidStateSid } = require("../../../workflow-state/state-io/state-root");
const { SESSION_ID_VALID_RE } = require("../../../workflow-state/state-io/core");
const stateLock = require("../../../workflow-state/state-io/state-lock");
const supervisorLock = require("../../supervisor-state-writer/lock");
const { LEGACY_ROOT, isSidEntry, isEntryShapedSid, isLegacySession } = require("./legacy");
const { buildRewriter } = require("./rewrite-root");
const { LOCKISH_RE, RelocationError, fault, copyTree } = require("./copy");
const { isMigratedEntry, reconcile, deleteLegacy, finishLegacy, countLeftovers } = require("./reconcile");

const REPORT_MARKER = "relocation-failure-reported";

function crash() {
  process.exit(1);
}

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
  } catch (_) { /* best-effort; the caller re-checks existence when it matters */ }
}

// Step 4: with no committed json, every new-root <sid> entry is a pre-commit leftover
// (a stopped move, or a #1658 stale .off-clearance) that no canonical writer can own.
// A work dir is `.relocating-<sid>-<pid>`, so another sid that merely extends this one
// (`<sid>-other`) never matches.
function sweepPreCommitLeftovers(sid, newRoot) {
  const work = (n) => n.startsWith(`.relocating-${sid}-`) && /^\d+$/.test(n.slice(`.relocating-${sid}-`.length));
  const stale = readNames(newRoot).filter((n) => isSidEntry(n, sid) || work(n));
  for (const n of stale) rmQuiet(path.join(newRoot, n));
  if (stale.some((n) => fs.existsSync(path.join(newRoot, n)))) throw new RelocationError("stale-new-entries");
}

function asRelocationError(e, code) {
  return e instanceof RelocationError ? e : new RelocationError(code, e);
}

// Step 7: everything but the json first, the json last (the commit point); step 8 on failure.
// From the control dir's publish on, its new-root supervisor lock is held too, so a
// supervisor writer that resolves the new root after the commit waits for afterCommit.
// A failed commit rolls back only after that lock is released (its release must not
// find the control dir gone).
function publish(sid, names, work, r, afterCommit) {
  const json = `${sid}.json`;
  const ctl = `${sid}.control`;
  const published = [];
  let committed = false;
  const commit = () => {
    if (fault() === "json-rename" || fault() === "rollback") throw new RelocationError("json-rename");
    if (names.includes(json)) fs.renameSync(path.join(work, json), path.join(r.newRoot, json));
    committed = true;
    rmQuiet(work);
    return afterCommit();
  };
  try {
    for (const n of names.filter((x) => x !== json)) {
      fs.renameSync(path.join(work, n), path.join(r.newRoot, n));
      published.push(n);
      if (n === ctl && fault() === "control-rename") crash();
    }
    if (!published.includes(ctl)) return commit();
    const supervisorPath = path.join(r.newRoot, ctl, "supervisor-state.json");
    const out = quietly(() => supervisorLock.withStateLock(supervisorPath, commit));
    if (out === undefined) throw new RelocationError("lock-timeout");
    return out;
  } catch (e) {
    if (committed) throw e;
    if (fault() === "rollback") crash();
    for (const n of published) rmQuiet(path.join(r.newRoot, n));
    rmQuiet(work);
    throw asRelocationError(e, "publish");
  }
}

// Why this order (#2512): once <new>/<sid>.json is committed, every writer resolves the
// new root and locks new-root paths, which the legacy locks do not cover. So the
// reconcile that catches legacy writes made since the copy runs first into the private
// work dir, and the new-root workflow-state lock (taken here) and supervisor lock (taken
// in publish) are held from before the commit through deleteLegacy. The one post-commit
// reconcile catches what unlocked writers did to legacy since (a `.workflow-off` written
// or unlinked) and leaves any new-root file another writer has touched alone.
function moveLocked(sid, r, timeoutMs) {
  if (!isLegacySession(sid, { newRoot: r.newRoot, home: r.home })) return { skipped: "already-new" };
  sweepPreCommitLeftovers(sid, r.newRoot);
  const newStateLock = `${path.join(r.newRoot, `${sid}.json`)}.lock`;
  return stateLock.withStateLockAt(newStateLock, () => moveHeld(sid, r), { timeoutMs });
}

function moveHeld(sid, r) {
  const names = readNames(r.legRoot).filter((n) => isMigratedEntry(n, sid));
  const work = path.join(r.newRoot, `.relocating-${sid}-${process.pid}`);
  const ctx = {
    copied: 0, snap: new Map(), dst: new Map(),
    rewrite: buildRewriter({ oldRoot: r.legRoot, newRoot: r.newRoot }),
  };
  let pre;
  try {
    fs.mkdirSync(work, { recursive: true });
    for (const n of names) copyTree(path.join(r.legRoot, n), path.join(work, n), ctx, n);
    pre = reconcile(sid, names, r, ctx, work);
  } catch (e) {
    rmQuiet(work);
    throw asRelocationError(e, "copy");
  }
  // A kept entry's newer content is still only in legacy; committing would strand it.
  if (pre.kept.length > 0) {
    rmQuiet(work);
    throw new RelocationError("reconcile");
  }
  const staged = pre.names.filter((n) => fs.existsSync(path.join(work, n)));
  return publish(sid, staged, work, r, () => {
    const settled = reconcile(sid, staged, r, ctx, r.newRoot);
    deleteLegacy(sid, settled.names, r.legRoot);
    return { moved: staged, touched: [...settled.names, ...settled.kept] };
  });
}

// The supervisor lock's fail-closed note goes to stderr; this CLI reports on stdout only.
function quietly(fn) {
  const saved = console.error;
  console.error = () => {};
  try {
    return fn();
  } finally {
    console.error = saved;
  }
}

function underLocks(sid, legRoot, fn) {
  const timeoutMs = Number(process.env.STATE_RELOCATION_LOCK_TIMEOUT_MS) || undefined;
  const supervisorPath = path.join(legRoot, `${sid}.control`, "supervisor-state.json");
  try {
    return stateLock.withStateLock(sid, () => {
      const out = quietly(() => supervisorLock.withStateLock(supervisorPath, () => fn(timeoutMs)));
      if (out === undefined) throw new RelocationError("lock-timeout");
      return out;
    }, { timeoutMs });
  } catch (e) {
    if (e instanceof stateLock.StateLockTimeoutError) throw new RelocationError("lock-timeout", e);
    throw e;
  }
}

// One report per session: the marker lives in the legacy control dir, so it adds no
// discriminator file and travels with the control dir once a later move succeeds.
function reportToken(sid, legRoot) {
  const ctl = path.join(legRoot, `${sid}.control`);
  try {
    fs.mkdirSync(ctl, { recursive: true });
    fs.closeSync(fs.openSync(path.join(ctl, REPORT_MARKER), "wx"));
    return "first";
  } catch (e) {
    return e && e.code === "EEXIST" ? "dup" : "first";
  }
}

// relocate(sid) -> the single stdout line. Throws only on an invalid sid.
function relocate(sid) {
  assertValidStateSid(sid);
  if (isEntryShapedSid(sid)) throw new Error(`sid is another session's entry name: ${sid}`);
  const skipped = (reason) => `RELOCATE_SKIPPED sid=${sid} reason=${reason}`;
  if (getStateRoot() !== getStateRoot({ envFallback: false })) return skipped("pinned");
  // The workflow-state lock path takes the narrower session-id form (no dots); such a
  // session stays in legacy and `remaining` keeps counting it.
  if (!SESSION_ID_VALID_RE.test(sid)) return skipped("unlockable-sid");
  const home = os.homedir();
  const r = { home, newRoot: getStateRoot(), legRoot: LEGACY_ROOT(home) };
  if (fs.existsSync(path.join(r.newRoot, `${sid}.json`))) return skipped("already-new");
  if (!readNames(r.legRoot).some((n) => isSidEntry(n, sid))) return skipped("no-entries");
  // Marker-only legacy entries: the session already routes to the new root, whose
  // entries are canonical and must not be swept as pre-commit leftovers.
  if (!isLegacySession(sid, { newRoot: r.newRoot, home })) return skipped("not-legacy");
  let result;
  try {
    result = underLocks(sid, r.legRoot, (timeoutMs) => moveLocked(sid, r, timeoutMs));
  } catch (e) {
    const code = e instanceof RelocationError ? e.code : "internal";
    return `RELOCATE_FAILED sid=${sid} reason=${code} report=${reportToken(sid, r.legRoot)}`;
  }
  if (result.skipped) return skipped(result.skipped);
  finishLegacy(sid, r.legRoot);
  const leftovers = countLeftovers(result.touched, r.legRoot);
  return `RELOCATED sid=${sid} entries=${result.moved.length} leftovers=${leftovers}`;
}

module.exports = { relocate };
