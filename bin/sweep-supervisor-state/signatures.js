#!/usr/bin/env node
"use strict";

// Allowlist of escape-hatch reasons that #1799-era leaking test suites wrote
// into real supervisor state files.
//
// Matching is EXACT on the captured reason, never substring: a human writing
// "test reason" or "recovery" must survive. Every entry below is a literal a
// test fixture emitted verbatim.
//
// Two entries are reasons a human could plausibly write, so they carry a
// co-occurrence condition: they are contamination only when a sibling record
// in the same file carries a test case label (A1 / SEC2 / C3 / ...).

const SIGNATURES = [
  "A1 marker test",
  "A3 non-zero exit",
  "A4 env-file fallback",
  "A5 no session id",
  "A6 chain test",
  "A7 idempotent write",
  "A14 transcript fallback",
  "A15 invalid chars",
  "C1 round trip",
  "C3 step1",
  "SEC1 traversal",
  "SEC2 metachars",
  "maintenance recovery",
  "standalone reason",
];

// Entries requiring a case-label sibling in the same file.
const CO_OCCURRENCE_REQUIRED = new Set(["maintenance recovery", "standalone reason"]);

// Reporters that emit escape-hatch findings. "workflow-mark" is the
// pre-record_type era name.
const EMITTER_REPORTERS = new Set(["enforce-override-handlers", "workflow-mark"]);

const DETAIL_RE = /^escape-hatch sentinel: (?:WORKTREE_OFF|WORKFLOW_OFF) \((.*)\)$/;

// A test case label: one to four uppercase letters followed by digits.
const CASE_LABEL_RE = /^[A-Z]{1,4}\d+\b/;

// reasonOf returns the captured escape-hatch reason, or null when the record
// is not an escape-hatch sentinel finding of the emitter shape.
function reasonOf(record) {
  if (!record || typeof record !== "object" || Array.isArray(record)) return null;
  if (record.severity !== "warning") return null;
  if (!Array.isArray(record.categories)) return null;
  if (record.categories.length !== 1 || record.categories[0] !== "workflow") return null;
  if (!EMITTER_REPORTERS.has(record.reporter)) return null;
  if (record.record_type !== undefined && record.record_type !== "escape_hatch_event") return null;
  if (typeof record.detail !== "string") return null;
  const m = record.detail.match(DETAIL_RE);
  return m ? m[1] : null;
}

// hasCaseLabelSibling reports whether some OTHER record in allRecords carries
// a case-label reason.
function hasCaseLabelSibling(record, allRecords) {
  if (!Array.isArray(allRecords)) return false;
  for (const other of allRecords) {
    if (other === record) continue;
    const r = reasonOf(other);
    if (r !== null && CASE_LABEL_RE.test(r)) return true;
  }
  return false;
}

// matchesSignature reports whether record is #1799 test contamination.
// allRecords is the full sibling set used for co-occurrence conditions.
function matchesSignature(record, allRecords) {
  const reason = reasonOf(record);
  if (reason === null) return false;
  if (!SIGNATURES.includes(reason)) return false;
  if (CO_OCCURRENCE_REQUIRED.has(reason)) {
    return hasCaseLabelSibling(record, allRecords);
  }
  return true;
}

if (require.main === module) {
  for (const s of SIGNATURES) process.stdout.write(s + "\n");
}

module.exports = { SIGNATURES, matchesSignature, reasonOf };
