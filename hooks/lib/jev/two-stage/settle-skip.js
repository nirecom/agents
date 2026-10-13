"use strict";
// hooks/lib/jev/two-stage/settle-skip.js — the skip owner marker MS (<target>-skip-owner.json)
// of outline-skip / detail-skip (#2460). The newest query owns MS from query time on; only the
// owner calls record-skip-judgment, under <target>-skip-owner.lock for the whole settle.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const { readVersioned } = require("../state-paths");
const { controlPath } = require("../../../workflow-state/state-io/control-dir");
const { compareOwner, acquireLock } = require("./settle-complexity");

const SKIP_OWNER_VERSION = 1;
const RSJ = path.join(__dirname, "..", "..", "..", "..", "bin", "workflow", "record-skip-judgment");

const files = (sid, target) => ({
  marker: controlPath(sid, `${target}-skip-owner.json`, { forWrite: true }),
  lock: controlPath(sid, `${target}-skip-owner.lock`, { forWrite: true }),
});

function writeOwner(file, owner) {
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify({
      version: SKIP_OWNER_VERSION, owner_id: owner.id, owner_created_ms: owner.created_ms, ts_ms: Date.now(),
    }));
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_e) { /* never written */ }
    throw e;
  }
}

const norm = (o) => ({ id: String(o.id), created_ms: Number(o.created_ms) });

// fn(marker, f) under the target's lock; throws when the lock is not taken.
function underLock(sid, target, fn) {
  const f = files(sid, target);
  if (!acquireLock(f.lock)) throw new Error("skip owner lock not acquired");
  try {
    return fn(readVersioned(f.marker, SKIP_OWNER_VERSION), f);
  } finally {
    try { fs.unlinkSync(f.lock); } catch (_e) { /* already gone */ }
  }
}

// Query time: owner becomes MS unless MS already names a newer owner. Throws on failure.
function takeSkipOwnerAtQuery(sid, target, ownerArg) {
  const owner = norm(ownerArg);
  underLock(sid, target, (m, f) => {
    if (m && compareOwner(m, owner) > 0) return;
    writeOwner(f.marker, owner);
  });
}

// settleSkip(sid, target, conditions, source, owner, tid) -> {settle, detail, owner, rsj_lines}.
// A newer MS supersedes without calling record-skip-judgment; otherwise MS is (re)written and
// record-skip-judgment --advance runs under the lock. Throws when it fails.
function settleSkip(sid, target, conditions, source, ownerArg, tid) {
  const owner = norm(ownerArg);
  return underLock(sid, target, (m, f) => {
    if (m && compareOwner(m, owner) > 0) {
      return { settle: "superseded", detail: "newer-owner", owner: m.owner_id, rsj_lines: [] };
    }
    writeOwner(f.marker, owner);
    const args = [RSJ, "--session", sid, "--target", target];
    for (const k of Object.keys(conditions)) args.push("--cond", `${k}=${conditions[k] === true}`);
    args.push("--source", source, "--ticket", tid, "--advance");
    const r = spawnSync(process.execPath, args, { encoding: "utf8", timeout: 30000, windowsHide: true });
    if (r.status !== 0) throw new Error("record-skip-judgment failed");
    const lines = String(r.stdout || "").split("\n").map((l) => l.replace(/\r$/, "")).filter((l) => l !== "");
    if (lines.includes("RECORDED=superseded")) {
      return { settle: "superseded", detail: "step-not-pending", owner: null, rsj_lines: lines };
    }
    return { settle: "ok", detail: null, owner: null, rsj_lines: lines };
  });
}

// The skip fail-safe: owner takes MS unless a newer owner holds it. No judgment is written.
function failsafeSkip(sid, target, ownerArg) {
  const owner = norm(ownerArg);
  return underLock(sid, target, (m, f) => {
    if (m && compareOwner(m, owner) > 0) return { settle: "superseded", detail: "newer-owner", owner: m.owner_id };
    writeOwner(f.marker, owner);
    return { settle: "ok", detail: null, owner: null };
  });
}

function readSkipOwner(sid, target) {
  try {
    return readVersioned(controlPath(sid, `${target}-skip-owner.json`), SKIP_OWNER_VERSION);
  } catch (_e) {
    return null;
  }
}

module.exports = { SKIP_OWNER_VERSION, takeSkipOwnerAtQuery, settleSkip, failsafeSkip, readSkipOwner };
