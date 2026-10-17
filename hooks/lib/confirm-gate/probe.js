"use strict";
// Resolves one CONFIRM_* gate to OFF / ON / ERROR by calling hooks/lib/config-flag.js
// in-process; config-flag.js owns the decision logic and never starts a subprocess.
// The cause says why a value is what it is: ok, load-failed (the .env could not be
// loaded), exception (config-flag or load-env threw or is missing) or over-budget.
// A synchronous in-process call cannot be cut short, so the budget is a diagnostic
// threshold: past it the value is kept and only the cause records the overrun.
// The sync and async flavours share probeConfirmGateWithCause.

const path = require("path");
const { CONFIRM_GATE_DEFAULTS } = require("./step-gate-map");

const PROBE_CAUSES = ["ok", "load-failed", "exception", "over-budget"];

// Forward slashes on purpose: the bash scripts it builds paths for break on a
// Windows backslash path.
function posixJoin(dir, ...rest) {
  return path.join(dir, ...rest).replace(/\\/g, "/");
}

function probeConfirmGateWithCause(key, budgetMs) {
  const started = Date.now();
  try {
    const cf = require("../config-flag");
    const r = cf.classifyConfigFlag(key, CONFIRM_GATE_DEFAULTS[key] || "on");
    if (r.kind === "failed") {
      return { value: "ERROR", cause: r.cause === "load-failed" ? "load-failed" : "exception" };
    }
    const value = cf.verdictOfKind(r.kind);
    const budgeted = typeof budgetMs === "number" && Number.isFinite(budgetMs) && budgetMs > 0;
    return { value, cause: budgeted && Date.now() - started > budgetMs ? "over-budget" : "ok" };
  } catch (_e) {
    return { value: "ERROR", cause: "exception" };
  }
}

function probeConfirmGateSync(key, timeoutMs) {
  return probeConfirmGateWithCause(key, timeoutMs).value;
}

// Never rejects: every failure is already an ERROR token.
function probeConfirmGate(key, timeoutMs) {
  return Promise.resolve(probeConfirmGateSync(key, timeoutMs));
}

module.exports = {
  PROBE_CAUSES,
  posixJoin,
  probeConfirmGateWithCause,
  probeConfirmGateSync,
  probeConfirmGate,
};
