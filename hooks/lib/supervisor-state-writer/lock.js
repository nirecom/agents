"use strict";

// #2256 S2-c — cross-process state lock.
// mkdir is the atomicity primitive; an `owner` token file inside identifies the
// holder so a stale-reclaim by another process cannot be clobbered on release.
// Accepted Tradeoff: no reclaim-then-race defense, no lease renewal.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { getStatePath, readStateOrInit, writeAtomic, sessionIdFromStatePath } = require("./shared");

const RETRY_INTERVAL_MS = 50;
const RETRY_LIMIT = 40;
const STALE_AFTER_MS = 10000;
const CREATION_GRACE_MS = 1000;
const OWNER_FILE = "owner";

// lockDir -> { token, depth }
const held = new Map();

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function mintToken() {
  const uuid = typeof crypto.randomUUID === "function"
    ? crypto.randomUUID()
    : crypto.randomBytes(16).toString("hex");
  return `${process.pid}-${uuid}`;
}

function isStale(lockDir) {
  try {
    const st = fs.statSync(lockDir);
    const age = Date.now() - st.mtimeMs;
    return age >= STALE_AFTER_MS && age >= CREATION_GRACE_MS;
  } catch (_) {
    return false;
  }
}

// Unlink the token before rmdir: a leftover owner file would otherwise make
// rmdir fail with ENOTEMPTY and wedge the lock forever.
function reclaim(lockDir) {
  try {
    for (const name of fs.readdirSync(lockDir)) {
      try {
        fs.unlinkSync(path.join(lockDir, name));
      } catch (_) {}
    }
  } catch (_) {}
  try {
    fs.rmdirSync(lockDir);
    return true;
  } catch (_) {
    return false;
  }
}

function acquire(lockDir) {
  for (let attempt = 0; attempt < RETRY_LIMIT; attempt++) {
    try {
      fs.mkdirSync(lockDir);
      const token = mintToken();
      fs.writeFileSync(path.join(lockDir, OWNER_FILE), token, "utf8");
      return token;
    } catch (err) {
      if (err && err.code !== "EEXIST") return null;
      if (isStale(lockDir) && reclaim(lockDir)) continue;
      sleepSync(RETRY_INTERVAL_MS);
    }
  }
  return null;
}

// Lock-free by design: the lock we would take is exactly the one we just lost.
function recordOwnershipMismatch(filePath, expected, found) {
  const sessionId = sessionIdFromStatePath(filePath);
  if (!sessionId) return;
  try {
    const state = readStateOrInit(sessionId);
    if (!state.layer1 || !Array.isArray(state.layer1.findings)) return;
    state.layer1.findings.push({
      severity: "warning",
      categories: ["workflow"],
      reporter: "supervisor-state-lock",
      detail: `state lock ownership mismatch on release: expected ${expected}, found ${found}`,
      reason: "mechanism",
      timestamp: new Date().toISOString(),
    });
    state.last_updated = new Date().toISOString();
    writeAtomic(filePath, state);
  } catch (_) {}
}

function release(filePath, lockDir, token) {
  const ownerPath = path.join(lockDir, OWNER_FILE);
  let found = null;
  try {
    found = fs.readFileSync(ownerPath, "utf8");
  } catch (_) {
    found = null;
  }
  if (found !== token) {
    recordOwnershipMismatch(filePath, token, found === null ? "REMOVED" : found);
    return;
  }
  try {
    fs.unlinkSync(ownerPath);
  } catch (_) {}
  try {
    fs.rmdirSync(lockDir);
  } catch (_) {}
}

// Runs fn while holding the lock for filePath. Reentrant within one process.
// Fail-closed: when the lock cannot be acquired, fn never runs and no exception
// escapes — the caller sees undefined and one stderr note.
function withStateLock(filePath, fn) {
  const lockDir = `${filePath}.lock`;
  const current = held.get(lockDir);
  if (current) {
    current.depth += 1;
    try {
      return fn();
    } finally {
      current.depth -= 1;
    }
  }

  try { fs.mkdirSync(path.dirname(filePath), { recursive: true }); } catch (_) { /* acquire reports it */ }
  const token = acquire(lockDir);
  if (token === null) {
    console.error(`[supervisor-state-lock] could not acquire ${lockDir} — write skipped (fail-closed)`);
    return undefined;
  }
  held.set(lockDir, { token, depth: 1 });
  try {
    return fn();
  } finally {
    held.delete(lockDir);
    release(filePath, lockDir, token);
  }
}

const MOVED = Symbol("supervisor-state-moved");
const MAX_REACQUIRE = 2;

// Resolve the session's supervisor-state path, lock it, and run fn under that lock.
// Same fail-closed contract as withStateLock: undefined + one stderr note when it cannot.
function withSessionStateLock(sessionId, fn) {
  let filePath = getStatePath(sessionId, { forWrite: true });
  for (let retry = 0; ; retry++) {
    let now = filePath;
    const r = withStateLock(filePath, () => {
      // --- BEGIN temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration added 2026-10-04 ---
      // deletion-condition: remove when bin/state-dir-relocation remaining exits 0 (no session with a <sid>.json or <sid>.control left in the legacy dir, any sid shape); also delete skills/session-close SC-9; review by 2027-01-04
      now = getStatePath(sessionId, { forWrite: true });
      if (now !== filePath) return MOVED;
      // --- END temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration ---
      return fn();
    });
    if (r !== MOVED) return r;
    if (retry >= MAX_REACQUIRE) {
      console.error(`[supervisor-state-lock] state for ${sessionId} moved more than ${MAX_REACQUIRE} times — write skipped (fail-closed)`);
      return undefined;
    }
    filePath = now;
  }
}

module.exports = {
  withStateLock,
  withSessionStateLock,
  RETRY_INTERVAL_MS,
  RETRY_LIMIT,
  STALE_AFTER_MS,
  CREATION_GRACE_MS,
};
