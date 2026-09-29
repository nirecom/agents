"use strict";
// Mechanical handoff records (#2430): facts a resuming session cannot rebuild
// from a compacted transcript — a compaction, a RESET_FROM rollback, a WARN/BLOCK
// audit verdict — recorded by the code that performs them, without the model.
//
// This module is the only owner of origin "auto-record" (CPR-SSOT). Every
// auto-record is also a risk signal for the omission-check nudge.

const path = require("path");
const { appendHandoffEntryIfActive } = require("./handoff-gated-append");
const { recordRiskSignal } = require("./handoff-risk-signal");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");

const AUTO_RECORD_ORIGIN = "auto-record";

// Stamps the risk, then writes through the active-period gate; options pass
// through to appendHandoffEntryIfActive. Returns {written, reason}. Never throws.
function appendAutoRecord(sid, entry, riskSource, options) {
  try {
    recordRiskSignal(sid, riskSource);
  } catch (_e) {
    /* a lost stamp costs nothing but the stamp */
  }
  try {
    const base = entry && typeof entry === "object" ? entry : {};
    return appendHandoffEntryIfActive(sid, Object.assign({}, base, { origin: AUTO_RECORD_ORIGIN }), options);
  } catch (_e) {
    return { written: false, reason: "io" };
  }
}

// Class E breadcrumb for an accepted WARN/BLOCK supervisor audit verdict; any
// other verdict records nothing. Never throws.
function recordVerdictBreadcrumb(sid, verdict, summary) {
  try {
    if (verdict !== "WARN" && verdict !== "BLOCK") return { written: false, reason: "not-applicable" };
    const text = typeof summary === "string" && summary.trim() ? `supervisor audit ${verdict}: ${summary}` : `supervisor audit ${verdict}`;
    return appendAutoRecord(sid, {
      cls: "E",
      step: "-",
      key: "supervisor-audit:verdict",
      summary: text,
      pointer: path.join(getWorkflowPlansDir(), `${sid}-supervisor-state.json`),
    }, "supervisor-verdict");
  } catch (_e) {
    return { written: false, reason: "io" };
  }
}

module.exports = { appendAutoRecord, recordVerdictBreadcrumb };
