#!/usr/bin/env node
// daemon-stop.js — stop the CodeGraph daemon holding <root>, or decline.
//
// Splitting this out of codegraph-lifecycle.js keeps the kill path — the only
// irreversible thing this feature does — readable on its own. It answers
// "should this pid die" with process-identity.js and never widens that answer.

// win32: Node maps SIGTERM and SIGKILL alike onto TerminateProcess, so the
// ladder below collapses into an immediate kill. CodeGraph's durable state is
// SQLite + WAL, which survives that.

process.removeAllListeners("warning");

const fs = require("fs");
const path = require("path");

const identity = require("./process-identity");
const { warn, report } = require("./diagnostics");

const TERM_WAIT_MS = 3000;
const KILL_WAIT_MS = 2000;
const POLL_MS = 100;

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function removeQuietly(target) {
  try {
    fs.rmSync(target, { force: true });
  } catch (_) {
    /* best-effort cleanup: a leftover file is not worth a diagnostic */
  }
}

// probeLiveness maps the three answers that mean something. Anything else —
// a pid Node refuses to convert, for instance — is "unknown", which must fall
// through to identification rather than be read as "gone".
function probeLiveness(pid) {
  try {
    process.kill(pid, 0);
    return "alive";
  } catch (err) {
    const code = err && err.code;
    if (code === "ESRCH") return "gone";
    if (code === "EPERM") return "foreign";
    return "unknown";
  }
}

function waitForExit(pid, budgetMs) {
  const deadline = Date.now() + budgetMs;
  for (;;) {
    if (probeLiveness(pid) === "gone") return true;
    if (Date.now() >= deadline) return false;
    sleep(POLL_MS);
  }
}

function signalQuietly(pid, signal) {
  try {
    process.kill(pid, signal);
  } catch (_) {
    /* the process may have exited between the probe and the signal */
  }
}

function terminate(pid) {
  signalQuietly(pid, "SIGTERM");
  if (waitForExit(pid, TERM_WAIT_MS)) return true;
  signalQuietly(pid, "SIGKILL");
  return waitForExit(pid, KILL_WAIT_MS);
}

// readPid returns a pid worth acting on, or null. Everything that is not a
// positive safe integer is refused here — before any signal and before the
// external command-line query, which is the injection surface. A string pid is
// refused too: past this gate String(pid) provably holds digits only.
function readPid(pidFile, root, announce) {
  let raw = null;
  try {
    raw = fs.readFileSync(pidFile, "utf8");
  } catch (_) {
    return null;
  }
  let lock = null;
  try {
    lock = JSON.parse(raw);
  } catch (_) {
    if (announce) warn("daemon.pid for " + root + " is not readable JSON; not stopping anything.");
    return null;
  }
  const pid = lock ? lock.pid : undefined;
  if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid <= 0) {
    if (announce) warn("daemon.pid for " + root + " holds an invalid pid; not stopping anything.");
    return null;
  }
  return pid;
}

// stopDaemon signals nothing it cannot positively identify as this root's
// daemon: killing the wrong process is unrecoverable, while failing to stop
// one only costs a retry. `announce` is false when init calls this to unlock
// the database files, so a repair never narrates its own housekeeping.
function stopDaemon(root, announce) {
  const indexDir = path.join(root, ".codegraph");
  const pidFile = path.join(indexDir, "daemon.pid");
  const pid = readPid(pidFile, root, announce);
  if (pid === null) return;

  const liveness = probeLiveness(pid);
  if (liveness === "gone") {
    removeQuietly(pidFile);
    return;
  }
  if (liveness === "foreign") {
    if (announce) warn("the process named in daemon.pid for " + root + " belongs to another user; leaving it alone.");
    return;
  }
  if (!identity.isDaemonForRoot(identity.readArgv(pid), root)) {
    if (announce) warn("pid " + pid + " is not the CodeGraph daemon for " + root + "; leaving it alone.");
    return;
  }
  if (!terminate(pid)) {
    if (announce) warn("the CodeGraph daemon (pid " + pid + ") for " + root + " did not exit; leaving it alone.");
    return;
  }
  removeQuietly(pidFile);
  removeQuietly(path.join(indexDir, "daemon.sock"));
  if (announce) report("stopped daemon (pid " + pid + ") for " + root);
}

module.exports = { stopDaemon };
