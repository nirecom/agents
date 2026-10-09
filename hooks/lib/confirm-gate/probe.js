"use strict";
// Resolves one CONFIRM_* gate to OFF / ON / ERROR by invoking bin/confirm-off,
// which stays the single owner of the decision logic.
// confirm-off exits 1 for ON and 2 for ERROR by design, so a nonzero status is
// normal and the stdout token — not the exit code — carries the answer. Only a
// spawn failure, a timeout, a kill or a throw is an ERROR of the probe itself.
// Two flavours share one invocation builder: async (parallel callers such as
// read-session-facts) and sync (next-step, which exits synchronously).

const path = require("path");
const { execFile, spawnSync } = require("child_process");
const { CONFIRM_GATE_DEFAULTS } = require("./step-gate-map");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");

const VERDICTS = ["OFF", "ON", "ERROR"];

function verdictOf(stdout) {
  const token = String(stdout == null ? "" : stdout).trim();
  return VERDICTS.indexOf(token) !== -1 ? token : "ERROR";
}

// Forward slashes on purpose: confirm-off is bash, and a Windows backslash path
// breaks the `dirname "$0"` idiom the script family relies on.
function posixJoin(dir, ...rest) {
  return path.join(dir, ...rest).replace(/\\/g, "/");
}

// The probe always runs the confirm-off of the checkout this file lives in, and
// the child inherits the environment unchanged: which .env it reads is the
// child's own decision.
function buildProbeInvocation(key, timeoutMs) {
  return {
    file: "bash",
    args: [posixJoin(SCRIPT_CHECKOUT_ROOT, "bin", "confirm-off"), key, CONFIRM_GATE_DEFAULTS[key] || "on"],
    opts: {
      cwd: SCRIPT_CHECKOUT_ROOT,
      env: process.env,
      timeout: timeoutMs,
      windowsHide: true,
      maxBuffer: 1024 * 1024,
    },
  };
}

function probeConfirmGate(key, timeoutMs) {
  return new Promise((resolve) => {
    try {
      const inv = buildProbeInvocation(key, timeoutMs);
      execFile(inv.file, inv.args, inv.opts, (err, stdout) => {
        if (err && err.killed) return resolve("ERROR");
        resolve(verdictOf(stdout));
      });
    } catch (e) {
      resolve("ERROR");
    }
  });
}

function probeConfirmGateSync(key, timeoutMs) {
  try {
    const inv = buildProbeInvocation(key, timeoutMs);
    const r = spawnSync(inv.file, inv.args, Object.assign({ encoding: "utf8" }, inv.opts));
    if (r.error || r.signal) return "ERROR";
    return verdictOf(r.stdout);
  } catch (e) {
    return "ERROR";
  }
}

module.exports = {
  verdictOf,
  posixJoin,
  buildProbeInvocation,
  probeConfirmGate,
  probeConfirmGateSync,
};
