"use strict";
// Comparison for one test: compares live (class, detail) with the decide output; returns a no-comparison reason or the result.
// main.js owns reading and calling decide; this file owns only how to compare.
const { findRecordForMismatch } = require("../run-tests-baseline-decide");

const NO = (reason) => ({ kind: "NO_COMPARISON", reason });
const CMP = (result, extra) => Object.assign({ kind: "COMPARED", result }, extra || {});

// One entry of the outside list: a detail string, or a { detailPattern, classes } entry.
function inOutside(outsideDetails, liveClass, liveDetail) {
  return (Array.isArray(outsideDetails) ? outsideDetails : []).some((e) => {
    if (typeof e === "string") return e === liveDetail;
    if (!e || !(e.detailPattern instanceof RegExp) || !e.detailPattern.test(String(liveDetail))) return false;
    return liveClass === undefined || !Array.isArray(e.classes) || e.classes.includes(liveClass);
  });
}

// A tab or newline in rel breaks the capture TSV columns, so such a row counts as unreadable.
const unreadable = (rel, captureRow) => typeof rel !== "string" || /[\t\r\n]/.test(rel) || typeof captureRow !== "string";

// compareOne({ rel, captureRow, decision, liveClass, liveDetail, outsideDetails, decideInput }) —
// decision is the decide output (class/detail with the rename and new-line marks main.js adds).
function compareOne(args) {
  const a = args || {};
  if (unreadable(a.rel, a.captureRow)) return NO("capture-unreadable");
  const d = a.decision;
  if (!d || typeof d !== "object") return NO("capture-unreadable");
  if (d.decidedOutsideDecide !== undefined) {
    if (inOutside(a.outsideDetails, a.liveClass, a.liveDetail)) return NO("outside-decide");
    return mismatch(a);
  }
  if (d.needsBaseResult) return NO("base-result-reused-from-ledger-or-inheritance");
  if (d.class === a.liveClass && d.detail === a.liveDetail) return CMP("match");
  return mismatch(a);
}

// Mismatch: recorded when a discrepancy record explains the live (class, detail), unrecorded otherwise.
function mismatch(a) {
  const rec = a.decideInput ? findRecordForMismatch(a.decideInput, { class: a.liveClass, detail: a.liveDetail }) : null;
  return rec ? CMP("recorded", { recordId: rec.id }) : CMP("unrecorded");
}

module.exports = { compareOne, inOutside };
