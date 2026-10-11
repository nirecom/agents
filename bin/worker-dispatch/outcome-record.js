"use strict";
// bin/worker-dispatch/outcome-record.js
// Writes the outcome record of one claimed dispatch (#2544): the result the caller is
// about to read on stdout, bound to the payload bytes it ran from. Exclusive create
// through fsguard's control-outcome file scope; the context naming that one file is
// built here and never reaches a worker.
const path = require("path");
const fsguard = require("./fsguard");
const emit = require("./emit");
const { realAbs } = require("./anchor");
const { getSessionControlDir } = require("../../hooks/workflow-state/state-io/control-dir");
const {
  buildOutcome,
  validateOutcome,
  outcomeFileName,
  payloadDigest,
} = require("../../hooks/lib/worker-outcome-contract");

const errText = (e) => (e && e.message ? e.message : "unknown error");

// Returns { ok: true } or { ok: false, reason }; never throws.
function recordOutcome({ workerName, entry, located, payloadBytes, rawCwd, result }) {
  try {
    const fields = emit.outcomeFields(entry, result);
    const outcome = buildOutcome(Object.assign({
      worker: workerName,
      stem: located.stem,
      session_id: located.sid,
      payload_sha256: payloadDigest(payloadBytes),
      cwd: typeof rawCwd === "string" ? rawCwd : "",
    }, fields));
    const checked = validateOutcome(outcome);
    if (!checked.ok) return { ok: false, reason: checked.reason };
    const controlDir = realAbs(getSessionControlDir(located.sid));
    if (controlDir === null) return { ok: false, reason: "session control directory is unresolvable" };
    const ctx = { controlDir, outcomeStem: located.stem };
    const target = path.join(controlDir, outcomeFileName(located.stem));
    fsguard.createExclusive(workerName, target, `${JSON.stringify(checked.outcome)}\n`, ctx);
    return { ok: true };
  } catch (e) {
    return { ok: false, reason: e && e.code === "EEXIST" ? "an outcome record already exists" : errText(e) };
  }
}

module.exports = { recordOutcome };
