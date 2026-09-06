"use strict";
// Answers the CONFIRM_TESTS / CONFIRM_CODE gates by invoking bin/confirm-off
// once per gate, both children IN PARALLEL.
// Parallelism is a necessary condition for #2102's goal, not an optimisation.
// Measured on Windows: sequential 2,579 ms vs parallel 1,695 ms, against the
// 2,533-3,862 ms call sequence this reader replaces — a sequential build is
// therefore no faster than the status quo and inverts the point of the issue.
// So: async child_process.execFile only — the synchronous spawn helpers
// serialise the children and are prohibited here (contract.sh C6b/C6c).
// Promise.allSettled, never Promise.all — one broken gate must not discard the
// verdict the other gate did produce.

const path = require("path");
const { execFile } = require("child_process");
const { normalizeCwd } = require("../../../../hooks/lib/path-normalize");
const { GATE_DEFAULTS } = require("./keys");

const DEFAULT_TIMEOUT_MS = 5000;
const VERDICTS = ["OFF", "ON", "ERROR"];

// confirm-off exits 1 for ON and 2 for ERROR by design, so a nonzero status is
// normal and the stdout token — not the exit code — carries the answer.
function verdictOf(stdout) {
  const token = String(stdout == null ? "" : stdout).trim();
  return VERDICTS.indexOf(token) !== -1 ? token : "ERROR";
}

// Forward slashes on purpose: confirm-off is bash, and a Windows backslash path
// breaks the `dirname "$0"` idiom the script family relies on.
function posixJoin(dir, ...rest) {
  return path.join(dir, ...rest).replace(/\\/g, "/");
}

function probeGate(configDir, key, timeoutMs) {
  return new Promise((resolve) => {
    const script = posixJoin(configDir, "bin", "confirm-off");
    const opts = {
      cwd: configDir,
      env: Object.assign({}, process.env, {
        AGENTS_CONFIG_DIR: configDir.replace(/\\/g, "/"),
      }),
      timeout: timeoutMs,
      windowsHide: true,
      maxBuffer: 1024 * 1024,
    };
    try {
      execFile("bash", [script, key, GATE_DEFAULTS[key]], opts, (err, stdout) => {
        if (err && err.killed) return resolve("ERROR");
        resolve(verdictOf(stdout));
      });
    } catch (e) {
      resolve("ERROR");
    }
  });
}

// Never throws and never rejects: every gate resolves to a value, so the caller
// keeps its fixed key set and its exit code independent of gate health.
async function readGateFacts(configDir, opts) {
  const dir = normalizeCwd(configDir) || configDir;
  const timeoutMs = (opts && opts.timeoutMs) || DEFAULT_TIMEOUT_MS;
  const keys = ["CONFIRM_TESTS", "CONFIRM_CODE"];
  const settled = await Promise.allSettled(
    keys.map((key) => probeGate(dir, key, timeoutMs))
  );
  const out = {};
  keys.forEach((key, i) => {
    const r = settled[i];
    out["GATE_" + key] = r && r.status === "fulfilled" ? r.value : "ERROR";
  });
  return out;
}

module.exports = { readGateFacts };
