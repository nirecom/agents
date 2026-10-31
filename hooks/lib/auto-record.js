"use strict";
// Mechanical state handoff records (#2430, #2652): facts a resuming session cannot rebuild
// from a compacted transcript — a compaction, a WARN/BLOCK audit verdict — recorded by the
// code that performs them, without the model.
//
// This module is the only owner of origin "auto-record" (CPR-SSOT). Every
// auto-record is also a risk signal for the omission-check nudge.

const { appendStateHandoffRecord } = require("./state-handoff-record");
const { recordRiskSignal } = require("./risk-signal");
const { controlPath, diagnoseControlMigration } = require("../workflow-state/state-io/control-dir");

const AUTO_RECORD_ORIGIN = "auto-record";

// Stamps the risk, then writes through the state handoff record entry (its recording
// period and budget apply). Returns {written, reason}. Never throws.
function appendAutoRecord(sid, entry, riskSource) {
  try {
    recordRiskSignal(sid, riskSource);
  } catch (_e) {
    /* a lost stamp costs nothing but the stamp */
  }
  try {
    const base = entry && typeof entry === "object" ? entry : {};
    return appendStateHandoffRecord(sid, Object.assign({}, base, { origin: AUTO_RECORD_ORIGIN }));
  } catch (_e) {
    return { written: false, reason: "io-error" };
  }
}

// Class E breadcrumb for an accepted WARN/BLOCK supervisor audit verdict; any
// other verdict records nothing. Never throws.
function recordVerdictBreadcrumb(sid, verdict, summary) {
  try {
    if (verdict !== "WARN" && verdict !== "BLOCK") return { written: false, reason: "not-applicable" };
    const text = typeof summary === "string" && summary.trim() ? `supervisor audit ${verdict}: ${summary}` : `supervisor audit ${verdict}`;
    let pointer = "-";
    try {
      pointer = controlPath(sid, "supervisor-state.json");
    } catch (e) {
      diagnoseControlMigration(e, "auto-record"); // a lost pointer costs nothing but the pointer
    }
    return appendAutoRecord(sid, {
      cls: "E",
      step: "-",
      key: "supervisor-audit:verdict",
      summary: text,
      pointer,
    }, "supervisor-verdict");
  } catch (_e) {
    return { written: false, reason: "io-error" };
  }
}

module.exports = { appendAutoRecord, recordVerdictBreadcrumb };
