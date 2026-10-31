"use strict";
// Case-marker placement (#2507 D7): which repo-relative tests/ paths the case-marker gate covers.
// A placed file is a category root or flat tests/<name> file, outside tests/_archive, tests/lib
// and tests/run-all.sh.

// placedMatch(rel) — the registry match of a file at a case-marker placement, or null.
function placedMatch(rel, reg) {
  if (typeof rel !== "string") return null;
  if (/^tests\/(_archive|lib)\//.test(rel) || rel === "tests/run-all.sh") return null;
  if (!/^tests\/((hooks|bin|skills|agents|install|tests)\/)?[^/]+$/.test(rel)) return null;
  const TLR = require("../test-language-registry");
  return TLR.matchBasename(rel.slice(rel.lastIndexOf("/") + 1), reg || TLR.loadRegistry());
}

const hasReader = (m) => m.status === "supported" && Boolean(m.entry.caseMarkerReader);

// caseMarkerEntry(rel) — the entry of a placed file with a caseMarkerReader, or null.
function caseMarkerEntry(rel, reg) {
  const m = placedMatch(rel, reg);
  return m && hasReader(m) ? m.entry : null;
}

const isCaseMarkerTarget = (rel, reg) => caseMarkerEntry(rel, reg) !== null;

// isReaderlessCaseMarkerTarget(rel) — a placed file some entry matches that has no caseMarkerReader.
function isReaderlessCaseMarkerTarget(rel, reg) {
  const m = placedMatch(rel, reg);
  return m !== null && !hasReader(m);
}

module.exports = { placedMatch, caseMarkerEntry, isCaseMarkerTarget, isReaderlessCaseMarkerTarget };
