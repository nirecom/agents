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
const { normalizeCwd } = require("../path-normalize");
const { CONFIRM_GATE_DEFAULTS } = require("./step-gate-map");

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

function resolveConfigDir() {
  const fromEnv = normalizeCwd(process.env.AGENTS_CONFIG_DIR);
  if (fromEnv) return fromEnv;
  return path.resolve(__dirname, "..", "..", "..");
}

function buildProbeInvocation(configDir, key, timeoutMs) {
  return {
    file: "bash",
    args: [posixJoin(configDir, "bin", "confirm-off"), key, CONFIRM_GATE_DEFAULTS[key] || "on"],
    opts: {
      cwd: configDir,
      env: Object.assign({}, process.env, {
        AGENTS_CONFIG_DIR: configDir.replace(/\\/g, "/"),
      }),
      timeout: timeoutMs,
      windowsHide: true,
      maxBuffer: 1024 * 1024,
    },
  };
}

function probeConfirmGate(configDir, key, timeoutMs) {
  return new Promise((resolve) => {
    if (!configDir) return resolve("ERROR");
    try {
      const inv = buildProbeInvocation(configDir, key, timeoutMs);
      execFile(inv.file, inv.args, inv.opts, (err, stdout) => {
        if (err && err.killed) return resolve("ERROR");
        resolve(verdictOf(stdout));
      });
    } catch (e) {
      resolve("ERROR");
    }
  });
}

function probeConfirmGateSync(configDir, key, timeoutMs) {
  if (!configDir) return "ERROR";
  try {
    const inv = buildProbeInvocation(configDir, key, timeoutMs);
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
  resolveConfigDir,
  buildProbeInvocation,
  probeConfirmGate,
  probeConfirmGateSync,
};
