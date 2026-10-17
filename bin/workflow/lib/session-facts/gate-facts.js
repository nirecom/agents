"use strict";
// Answers the CONFIRM_TESTS / CONFIRM_CODE gates by in-process resolution through
// the confirm-gate probe (hooks/lib/config-flag.js); no child process is started.
// A synchronous resolution that starts no child process is allowed. Starting a
// child process to resolve a gate — synchronous or asynchronous — must not come
// back: the spawn era serialised the gates (sequential 2,579 ms vs parallel 1,695 ms
// on Windows, #2102). The C6b/C6c string pins in contract.sh guard that line.
// Promise.allSettled, never Promise.all — one broken gate must not discard the
// verdict the other gate did produce.

const { probeConfirmGate } = require("../../../../hooks/lib/confirm-gate/probe");
const { GATE_DEFAULTS } = require("./keys");

const DEFAULT_TIMEOUT_MS = 5000;

// Never throws and never rejects: every gate resolves to a value, so the caller
// keeps its fixed key set and its exit code independent of gate health.
async function readGateFacts(opts) {
  const timeoutMs = (opts && opts.timeoutMs) || DEFAULT_TIMEOUT_MS;
  const keys = Object.keys(GATE_DEFAULTS);
  const settled = await Promise.allSettled(
    keys.map((key) => probeConfirmGate(key, timeoutMs))
  );
  const out = {};
  keys.forEach((key, i) => {
    const r = settled[i];
    out["GATE_" + key] = r && r.status === "fulfilled" ? r.value : "ERROR";
  });
  return out;
}

module.exports = { readGateFacts };
