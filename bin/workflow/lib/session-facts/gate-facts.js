"use strict";
// Answers the CONFIRM_TESTS / CONFIRM_CODE gates by invoking bin/confirm-off
// once per gate, both children IN PARALLEL.
// Parallelism is a necessary condition for #2102's goal, not an optimisation.
// Measured on Windows: sequential 2,579 ms vs parallel 1,695 ms, against the
// 2,533-3,862 ms call sequence this reader replaces — a sequential build is
// therefore no faster than the status quo and inverts the point of the issue.
// So: the async probe only — the synchronous spawn helpers serialise the
// children and are prohibited here (contract.sh C6b/C6c).
// Promise.allSettled, never Promise.all — one broken gate must not discard the
// verdict the other gate did produce.

const { normalizeCwd } = require("../../../../hooks/lib/path-normalize");
const { probeConfirmGate } = require("../../../../hooks/lib/confirm-gate/probe");
const { GATE_DEFAULTS } = require("./keys");

const DEFAULT_TIMEOUT_MS = 5000;

// Never throws and never rejects: every gate resolves to a value, so the caller
// keeps its fixed key set and its exit code independent of gate health.
async function readGateFacts(configDir, opts) {
  const dir = normalizeCwd(configDir) || configDir;
  const timeoutMs = (opts && opts.timeoutMs) || DEFAULT_TIMEOUT_MS;
  const keys = Object.keys(GATE_DEFAULTS);
  const settled = await Promise.allSettled(
    keys.map((key) => probeConfirmGate(dir, key, timeoutMs))
  );
  const out = {};
  keys.forEach((key, i) => {
    const r = settled[i];
    out["GATE_" + key] = r && r.status === "fulfilled" ? r.value : "ERROR";
  });
  return out;
}

module.exports = { readGateFacts };
