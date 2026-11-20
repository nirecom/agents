#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-run-tests/dispatch-outcome.js
// Tags: TL2, hooks, run-tests, dispatch-outcome, state-lock, fixture, scope:issue-specific
// Child of the #3073 C1 lock cases. argv: <mode> <sid> <signal-dir>. hold: take the state lock
// (after <dir>/acquire when <dir>/wait-acquire exists), touch held, wait go, ingest in-process
// when <dir>/ingest exists (touch ingest-done), wait release. apply: one applyDispatchOutcome,
// logging scan / lock-wait / lock-acquired / marker to apply.log; <dir>/pause holds the first
// .ingested write until held (at most PAUSE_MS). reenter: apply inside its own withStateLock.

const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..", "..", "..");
const [mode, sid, dir] = process.argv.slice(2);
// Every wait derives from the one lock timeout lock.js pins (F3073_LOCK_TIMEOUT_MS).
const LOCK_TIMEOUT_MS = Number(process.env.F3073_LOCK_TIMEOUT_MS);
if (!(LOCK_TIMEOUT_MS > 0)) {
  process.stderr.write("lock-child: F3073_LOCK_TIMEOUT_MS is not set\n");
  process.exit(2);
}
const WAIT_MS = LOCK_TIMEOUT_MS * 10;
const PAUSE_MS = LOCK_TIMEOUT_MS / 2;
const HOLDER_TIMEOUT_MS = LOCK_TIMEOUT_MS * 5;
const sig = (name) => path.join(dir, name);
const has = (name) => fs.existsSync(sig(name));
const touch = (name) => fs.writeFileSync(sig(name), `${process.pid}\n`);

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
function waitFor(name, ms) {
  const deadline = Date.now() + ms;
  while (!has(name)) {
    if (Date.now() >= deadline) return false;
    sleep(10);
  }
  return true;
}

const lock = require(path.join(ROOT, "hooks/workflow-state/state-io/state-lock.js"));
const core = require(path.join(ROOT, "hooks/workflow-state/state-io/core.js"));
const D = require(path.join(ROOT, "hooks/workflow-run-tests/dispatch-outcome.js"));
const apply = () => D.applyDispatchOutcome({ sessionId: sid, triggerCommand: "git status", isTest: false });
const report = (fn) => {
  try {
    const r = fn();
    process.stdout.write(`${JSON.stringify({ ok: true, ingested: r.ingested, unsettledStem: r.unsettledStem })}\n`);
  } catch (e) {
    process.stdout.write(`${JSON.stringify({ ok: false, name: e && e.name, message: e && e.message })}\n`);
  }
};

// Observation only: the original call always runs and its result or error passes through.
function instrument() {
  const controlDir = path.resolve(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`));
  // The path state-lock.js derives (lockPathFor): only that file counts as the state lock.
  const stateLock = path.resolve(core.getStatePath(sid) + ".lock");
  const log = (what) => fs.appendFileSync(sig("apply.log"), `${what} ${Date.now()}\n`);
  const { readdirSync, openSync, writeFileSync } = fs;
  let waited = false;
  let marked = false;
  fs.readdirSync = function (p, ...rest) {
    if (typeof p === "string" && path.resolve(p) === controlDir) log("scan");
    return readdirSync.call(fs, p, ...rest);
  };
  fs.openSync = function (p, flags, ...rest) {
    const isLock = typeof p === "string" && flags === "wx" && path.resolve(p) === stateLock;
    try {
      const fd = openSync.call(fs, p, flags, ...rest);
      if (isLock) log("lock-acquired");
      return fd;
    } catch (e) {
      if (isLock && e && e.code === "EEXIST" && !waited) {
        waited = true;
        log("lock-wait");
      }
      throw e;
    }
  };
  fs.writeFileSync = function (p, ...rest) {
    const r = writeFileSync.call(fs, p, ...rest);
    if (typeof p === "string" && p.endsWith(".ingested") && !marked) {
      marked = true;
      log("marker");
      if (has("pause")) {
        touch("paused");
        waitFor("held", PAUSE_MS);
      }
    }
    return r;
  };
}

if (mode === "hold") {
  if (has("wait-acquire") && !waitFor("acquire", WAIT_MS)) process.exit(3);
  lock.withStateLock(sid, () => {
    touch("held");
    if (!waitFor("go", WAIT_MS)) return;
    if (has("ingest")) {
      apply();
      touch("ingest-done");
    }
    waitFor("release", WAIT_MS);
  }, { timeoutMs: HOLDER_TIMEOUT_MS });
  touch("released");
} else if (mode === "apply") {
  instrument();
  report(apply);
} else if (mode === "reenter") {
  report(() => lock.withStateLock(sid, apply));
} else {
  process.stderr.write(`lock-child: unknown mode ${String(mode)}\n`);
  process.exit(2);
}
