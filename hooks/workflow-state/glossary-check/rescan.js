"use strict";
// hooks/workflow-state/glossary-check/rescan.js — the glossary-only staleness of a glossary_check
// record (#2962), private to record.js. When only the glossary changed, the step's own inputs are
// scanned again: the record stays current when the findings ([norm, variant, where]) are the same
// and no recorded norm's matching fields (term_fields) moved. Any other change is stale as before.

const path = require("path");
const { sameTermFields, termIn } = require("./grant-carry");

const SCAN = path.join(__dirname, "..", "..", "..", "bin", "lib", "glossary-drift", "scan.js");

const asArray = (v) => (Array.isArray(v) ? v : []);
const keyOf = (f) => JSON.stringify([f && f.norm, f && f.variant, f && f.where]);

// rescanVerdict(rec, changed, loaded, termFields) -> { current: true } | { current: false, terms? }
// | { error }. terms: the terms whose finding appeared or vanished, or whose matching fields moved.
function rescanVerdict(rec, changed, loaded, termFields) {
  const tf = rec && rec.term_fields;
  if (changed.length !== 1 || changed[0] !== "glossary" || !tf || typeof tf !== "object") return { current: false };
  let hits;
  try {
    hits = require(SCAN).scanStageInputs(loaded);
  } catch (e) {
    return { error: e && e.message ? e.message : String(e) };
  }
  if (!Array.isArray(hits)) return { error: "the scan returned no finding list" };
  const findings = asArray(rec.findings);
  const was = new Set(findings.map(keyOf));
  const now = new Set(hits.map(keyOf));
  const terms = new Set();
  for (const h of hits) if (!was.has(keyOf(h))) terms.add(String(h.term));
  for (const f of findings) if (!now.has(keyOf(f))) terms.add(String(f.term));
  for (const norm of Object.keys(tf)) {
    if (!sameTermFields(tf, termFields, norm)) terms.add(termIn(findings, norm));
  }
  return terms.size === 0 ? { current: true } : { current: false, terms: [...terms] };
}

module.exports = { rescanVerdict };
