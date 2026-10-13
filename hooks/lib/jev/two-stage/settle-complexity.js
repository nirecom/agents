"use strict";
// hooks/lib/jev/two-stage/settle-complexity.js — the only writer of the fixed
// <control dir>/<stage>-signals.txt (F) on the CLI path, with its owner marker M
// (<stage>-signals-owner.json). Ownership is decided by M alone, never by F's content:
// the judgment queried later wins (compareOwner), and an unowned write after our query
// supersedes us. Decision and write run under <stage>-signals-owner.lock (wx).

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

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

// The write (rule 4): M writing -> merged file -> the unmodified normalizer derives F -> F
// must equal signalsCsv -> M written with sha256(F). Throws on any failure (M stays writing).
function writeOwned(sid, stage, mergedLine, signalsCsv, owner, files, opts) {
  writeMarker(files.marker, owner, "writing", null);
  crash(opts, "after-owner-writing");
  const merged = controlPath(sid, `${stage}-jev-${owner.id}-merged.txt`, { forWrite: true });
  fs.writeFileSync(merged, mergedLine + "\n");
  const r = spawnSync(process.execPath, [NORMALIZER, "--raw-file", merged, "--session", sid, "--stage", stage],
    { encoding: "utf8", timeout: 30000, windowsHide: true });
  if (r.status !== 0) throw new Error("normalize-judge-signals failed");
  const bytes = fs.readFileSync(files.signals);
  if (bytes.toString("utf8").trim() !== signalsCsv) throw new Error("fixed signals file does not match");
  writeMarker(files.marker, owner, "written", sha256(bytes));
}

// The verdict under the lock: {settle: ok|superseded|write, detail, owner}.
function decide(files, owner, signalsCsv) {
  const m = readMarker(files.marker);
  const st = statOrNull(files.signals);
  const bytes = st ? fs.readFileSync(files.signals) : null;
  const fSha = bytes ? sha256(bytes) : null;
  if (m && m.owner_id === owner.id) {
    if (m.state === "writing") {
      // An interrupted write left F untouched (older than M) or holding our value; an F
      // written after M with another value is an unowned write and stands.
      if (st && st.mtimeMs >= m.ts_ms && bytes.toString("utf8").trim() !== signalsCsv) {
        return { settle: "superseded", detail: "unowned-write", owner: null };
      }
      return { settle: "write" };
    }
    if (m.state === "written" && fSha !== null && fSha === m.signals_sha256) return { settle: "ok", detail: null, owner: null };
    return { settle: "superseded", detail: "unowned-write", owner: null };
  }
  if (m && compareOwner(m, owner) > 0) return { settle: "superseded", detail: "newer-owner", owner: m.owner_id };
  if (st && st.mtimeMs >= owner.created_ms && (!m || fSha !== m.signals_sha256)) {
    return { settle: "superseded", detail: "unowned-write", owner: null };
  }
  return { settle: "write" };
}

// settleComplexity(sid, stage, mergedLine, signalsCsv, {id, created_ms}, opts?) ->
// {settle: "ok"|"superseded", detail, owner}. Throws when the lock or the write fails.
function settleComplexity(sid, stage, mergedLine, signalsCsv, ownerArg, opts = {}) {
  const owner = { id: String(ownerArg.id), created_ms: Number(ownerArg.created_ms) };
  const files = {
    marker: controlPath(sid, `${stage}-signals-owner.json`, { forWrite: true }),
    signals: controlPath(sid, `${stage}-signals.txt`, { forWrite: true }),
  };
  const lock = controlPath(sid, `${stage}-signals-owner.lock`, { forWrite: true });
  if (!acquireLock(lock)) throw new Error("signals owner lock not acquired");
  try {
    const v = decide(files, owner, signalsCsv);
    if (v.settle !== "write") return v;
    writeOwned(sid, stage, mergedLine, signalsCsv, owner, files, opts);
    return { settle: "ok", detail: null, owner: null };
  } finally {
    try { fs.unlinkSync(lock); } catch (_e) { /* already gone */ }
  }
}

// Read-only: the current owner marker of the stage (null when absent or of another version).
function readOwner(sid, stage) {
  try {
    return readMarker(controlPath(sid, `${stage}-signals-owner.json`));
  } catch (_e) {
    return null;
  }
}

module.exports = { SIGNALS_OWNER_VERSION, compareOwner, acquireLock, settleComplexity, readOwner };
