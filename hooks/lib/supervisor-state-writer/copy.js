"use strict";

// #2304 — copy a session upstream's supervisor state beside the downstream's
// copied workflow state, so findings and audit verdicts travel with the session.
// Only `session_id` is rewritten, plus one settlement: an audit run still unsettled
// upstream (pending / in_progress / frozen) belongs to the upstream's triggers, and
// armCore returns an in-flight run instead of minting one, so the downstream could
// never arm an audit of its own. That run is marked superseded and the phase cleared;
// every other field, settled verdicts included, is carried verbatim.
// Never throws: the outcome is reported, and inheritance treats it as advisory.

const fs = require("fs");
const { getStatePath, writeAtomic } = require("./shared");
const { withSessionStateLock } = require("./lock");
const { UNSETTLED_AUDIT_PHASES } = require("../supervisor-state-schema");
const { markLedgerEntrySuperseded } = require("../audit-ledger");

function settleInheritedAudit(audit) {
  if (!audit || typeof audit !== "object" || !UNSETTLED_AUDIT_PHASES.includes(audit.audit_phase)) return;
  if (typeof audit.audit_run_id === "string" && Array.isArray(audit.ledger)) {
    markLedgerEntrySuperseded(audit, audit.audit_run_id, new Date().toISOString());
  }
  audit.audit_phase = null;
  delete audit.pending_sub_checks;
  delete audit.audit_dispatched_at;
}

// copySupervisorState(fromSid, toSid) -> "copied" | "absent" | "failed".
function copySupervisorState(fromSid, toSid) {
  let raw;
  try {
    raw = fs.readFileSync(getStatePath(fromSid), "utf8");
  } catch (e) {
    return e && e.code === "ENOENT" ? "absent" : "failed";
  }
  try {
    const state = JSON.parse(raw);
    if (!state || typeof state !== "object" || Array.isArray(state)) return "failed";
    if (Object.prototype.hasOwnProperty.call(state, "session_id")) state.session_id = toSid;
    settleInheritedAudit(state.audit);
    const ok = withSessionStateLock(toSid, () => {
      writeAtomic(getStatePath(toSid, { forWrite: true }), state);
      return true;
    });
    return ok === true ? "copied" : "failed";
  } catch (_) {
    return "failed";
  }
}

module.exports = { copySupervisorState };
