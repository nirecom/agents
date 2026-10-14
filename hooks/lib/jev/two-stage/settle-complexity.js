"use strict";
// hooks/lib/jev/two-stage/settle-complexity.js — the only writer of the fixed
// <control dir>/<stage>-signals.txt (F) on the CLI path, with its owner marker M
// (<stage>-signals-owner.json). Ownership is decided by M alone, never by F's content:
// the judgment queried later wins (compareOwner) and takes M at query time, and an unowned
// write after our query supersedes us. Decision and write run under
// <stage>-signals-owner.lock (wx); the write itself is a compare-and-write (writeOwned).

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const { FINALIZE_CLAIM_STALE_MS } = require("../pending");
const { readVersioned } = require("../state-paths");
const { controlPath } = require("../../../workflow-state/state-io/control-dir");

const SIGNALS_OWNER_VERSION = 1;
const CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const NORMALIZER = path.join(CHECKOUT_ROOT, "bin", "workflow", "normalize-judge-signals");
const LOCK_WAIT_MS = 3000;
const LOCK_STEP_MS = 50;

const sha256 = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

function ownerOf(o) {
  const id = o && (o.id !== undefined ? o.id : o.owner_id);
  const ms = o && (o.created_ms !== undefined ? o.created_ms : o.owner_created_ms);
  return { id: String(id), ms: Number(ms) };
}

// compareOwner(a, b) -> >0 when a was queried later than b (a wins), <0 when earlier, 0 when
// the same owner. Ties on the query time: a failsafe- owner beats a ticket id; owners of the
// same kind compare by id. Takes {id, created_ms} or marker-shaped {owner_id, owner_created_ms}.
function compareOwner(a, b) {
  const x = ownerOf(a);
  const y = ownerOf(b);
  if (x.ms !== y.ms) return x.ms > y.ms ? 1 : -1;
  const fx = x.id.startsWith("failsafe-");
  const fy = y.id.startsWith("failsafe-");
  if (fx !== fy) return fx ? 1 : -1;
  if (x.id === y.id) return 0;
  return x.id > y.id ? 1 : -1;
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// False only when the lock's recorded pid is known to be gone (ESRCH).
function holderGone(lock) {
  try {
    const pid = Number(fs.readFileSync(lock, "utf8"));
    if (!Number.isSafeInteger(pid) || pid <= 0 || pid === process.pid) return false;
    process.kill(pid, 0);
    return false;
  } catch (e) {
    return Boolean(e && e.code === "ESRCH");
  }
}

// wx lock; a lock older than FINALIZE_CLAIM_STALE_MS, or whose holder has exited, is stolen.
// False when not taken in time.
function acquireLock(lock) {
  const deadline = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try {
      fs.writeFileSync(lock, String(process.pid), { flag: "wx" });
      return true;
    } catch (e) {
      if (!e || e.code !== "EEXIST") return false;
    }
    try {
      if (Date.now() - fs.statSync(lock).mtimeMs > FINALIZE_CLAIM_STALE_MS || holderGone(lock)) {
        fs.unlinkSync(lock);
        continue;
      }
    } catch (_e) { continue; }
    if (Date.now() >= deadline) return false;
    sleepMs(LOCK_STEP_MS);
  }
}

function writeMarker(file, owner, state, signalsSha) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify({
    version: SIGNALS_OWNER_VERSION, owner_id: owner.id, owner_created_ms: owner.created_ms,
    state, signals_sha256: signalsSha, ts_ms: Date.now(),
  }));
  fs.renameSync(tmp, file);
}

function readMarker(file) {
  return readVersioned(file, SIGNALS_OWNER_VERSION);
}

function statOrNull(p) {
  try { return fs.statSync(p); } catch (_e) { return null; }
}

function crash(opts, at) {
  if (opts && opts.crashAt === at) process.exit(99);
}

const UNOWNED = Object.freeze({ settle: "superseded", detail: "unowned-write", owner: null });

function shaOrNull(file) {
  try { return sha256(fs.readFileSync(file)); } catch (_e) { return null; }
}

// Puts the set-aside F back unless a writer created a new one meanwhile (that one stands).
function restoreAside(files) {
  try { fs.copyFileSync(files.aside, files.signals, fs.constants.COPYFILE_EXCL); } catch (_e) { /* F exists again */ }
  fs.rmSync(files.aside, { force: true });
}

// The compare-and-write. A writer that takes no lock (an unowned write) can land between the
// verdict and the write, so F is never overwritten in place: it is renamed aside, the bytes
// set aside must be the ones the verdict saw (seenSha), and the new F is created exclusively.
// An unowned write on either side of the rename is therefore kept, never written over.
// False when one was found (M stays writing, so a replay reads the same verdict); throws on
// any other failure.
function writeOwned(mergedLine, signalsCsv, owner, files, seenSha, opts) {
  if (require(NORMALIZER).normalize(mergedLine) !== signalsCsv) throw new Error("merged line does not normalize to the signals");
  writeMarker(files.marker, owner, "writing", seenSha);
  crash(opts, "after-owner-writing");
  fs.rmSync(files.aside, { force: true });
  let moved = true;
  try {
    fs.renameSync(files.signals, files.aside);
  } catch (e) {
    if (!e || e.code !== "ENOENT") throw e;
    moved = false;
  }
  if ((moved ? shaOrNull(files.aside) : null) !== seenSha) {
    if (moved) restoreAside(files);
    return false;
  }
  const bytes = Buffer.from(signalsCsv, "utf8");
  try {
    fs.writeFileSync(files.signals, bytes, { flag: "wx" });
  } catch (e) {
    fs.rmSync(files.aside, { force: true });
    if (e && e.code === "EEXIST") return false;
    throw e;
  }
  fs.rmSync(files.aside, { force: true });
  writeMarker(files.marker, owner, "written", sha256(bytes));
  return true;
}

// Our own marker's verdict. queried: F must still be the bytes seen at query time. writing:
// an interrupted write left F absent, untouched or holding our value; anything else is an
// unowned write and stands.
function decideOwned(m, st, bytes, fSha, signalsCsv) {
  if (m.state === "queried") return fSha === m.signals_sha256 ? { settle: "write" } : UNOWNED;
  if (m.state === "writing") {
    if (bytes === null || bytes.toString("utf8").trim() === signalsCsv) return { settle: "write" };
    const untouched = typeof m.signals_sha256 === "string" ? fSha === m.signals_sha256 : st.mtimeMs < m.ts_ms;
    return untouched ? { settle: "write" } : UNOWNED;
  }
  if (m.state === "written" && fSha !== null && fSha === m.signals_sha256) return { settle: "ok", detail: null, owner: null };
  return UNOWNED;
}

// The verdict under the lock: {settle: ok|superseded|write, detail, owner, seen}; seen is
// the sha256 of F as read here (null when absent), which the write then compares against.
function decide(files, owner, signalsCsv) {
  const m = readMarker(files.marker);
  const st = statOrNull(files.signals);
  const bytes = st ? fs.readFileSync(files.signals) : null;
  const fSha = bytes ? sha256(bytes) : null;
  let v = { settle: "write" };
  if (m && m.owner_id === owner.id) v = decideOwned(m, st, bytes, fSha, signalsCsv);
  else if (m && compareOwner(m, owner) > 0) v = { settle: "superseded", detail: "newer-owner", owner: m.owner_id };
  else if (st && st.mtimeMs >= owner.created_ms && (!m || fSha !== m.signals_sha256)) v = UNOWNED;
  return Object.assign({ seen: fSha }, v);
}

function filesOf(sid, stage) {
  const signals = controlPath(sid, `${stage}-signals.txt`, { forWrite: true });
  return {
    marker: controlPath(sid, `${stage}-signals-owner.json`, { forWrite: true }),
    lock: controlPath(sid, `${stage}-signals-owner.lock`, { forWrite: true }),
    signals, aside: `${signals}.aside`,
  };
}

// fn(files) under the stage's lock; throws when the lock is not taken.
function underLock(sid, stage, fn) {
  const files = filesOf(sid, stage);
  if (!acquireLock(files.lock)) throw new Error("signals owner lock not acquired");
  try {
    return fn(files);
  } finally {
    try { fs.unlinkSync(files.lock); } catch (_e) { /* already gone */ }
  }
}

const norm = (o) => ({ id: String(o.id), created_ms: Number(o.created_ms) });

// Query time: owner becomes M (state queried, with F's sha256 as it stands) unless M already
// names a newer owner. From here on an older judgment still in flight is superseded, and a
// write to F that this ticket did not make is detected by content. Throws on failure.
function takeSignalsOwnerAtQuery(sid, stage, ownerArg) {
  const owner = norm(ownerArg);
  underLock(sid, stage, (files) => {
    const m = readMarker(files.marker);
    if (m && compareOwner(m, owner) > 0) return;
    writeMarker(files.marker, owner, "queried", shaOrNull(files.signals));
  });
}

// settleComplexity(sid, stage, mergedLine, signalsCsv, {id, created_ms}, opts?) ->
// {settle: "ok"|"superseded", detail, owner}. Throws when the lock or the write fails.
function settleComplexity(sid, stage, mergedLine, signalsCsv, ownerArg, opts = {}) {
  const owner = norm(ownerArg);
  return underLock(sid, stage, (files) => {
    const { seen, ...v } = decide(files, owner, signalsCsv);
    if (v.settle !== "write") return v;
    return writeOwned(mergedLine, signalsCsv, owner, files, seen, opts) ? { settle: "ok", detail: null, owner: null } : UNOWNED;
  });
}

// Read-only: the current owner marker of the stage (null when absent or of another version).
function readOwner(sid, stage) {
  try {
    return readMarker(controlPath(sid, `${stage}-signals-owner.json`));
  } catch (_e) {
    return null;
  }
}

module.exports = {
  SIGNALS_OWNER_VERSION, compareOwner, acquireLock, takeSignalsOwnerAtQuery, settleComplexity, readOwner,
};
