"use strict";
// Case-marker placement (#2507 D7, #2473): which repo-relative tests/ paths the case-marker gate covers.
// A placed file is a category root or flat <tests.dir>/<name> file of the repo's .agents.json tests
// section — never a support dir file, a suite subfile or the runner. Without a root (or for an
// uninitialized repo) the legacy layout of registry.layoutFor applies.

const R = require("./registry");

// placedMatch(rel, reg, root) — the registry match of a file at a case-marker placement, or null.
function placedMatch(rel, reg, root) {
  if (typeof rel !== "string") return null;
  const p = R.placementOf(root, rel);
  if (p.kind !== "category" && p.kind !== "flat") return null;
  const TLR = require("../test-language-registry");
  return TLR.matchBasename(rel.slice(rel.lastIndexOf("/") + 1), reg || TLR.loadRegistry());
}

// caseMarkerOff(root) — the repo's .agents.json turns the case-marker gate off.
const caseMarkerOff = (root) => {
  const l = R.layoutFor(root);
  return l.initialized && l.caseMarker === "off";
};

const hasReader = (m) => m.status === "supported" && Boolean(m.entry.caseMarkerReader);

// readerEntry(rel, reg, root) — the entry of a placed file with a caseMarkerReader, caseMarker
// switch aside (the self-impl and test-runner checks of the same file still apply), or null.
function readerEntry(rel, reg, root) {
  const m = placedMatch(rel, reg, root);
  return m && hasReader(m) ? m.entry : null;
}

// caseMarkerEntry(rel, reg, root) — readerEntry of a repo whose caseMarker is not off, or null.
const caseMarkerEntry = (rel, reg, root) => (caseMarkerOff(root) ? null : readerEntry(rel, reg, root));

const isCaseMarkerTarget = (rel, reg, root) => caseMarkerEntry(rel, reg, root) !== null;

// isReaderlessCaseMarkerTarget(rel, reg, root) — a placed file some entry matches that has no caseMarkerReader.
function isReaderlessCaseMarkerTarget(rel, reg, root) {
  if (caseMarkerOff(root)) return false;
  const m = placedMatch(rel, reg, root);
  return m !== null && !hasReader(m);
}

module.exports = { placedMatch, caseMarkerOff, readerEntry, caseMarkerEntry, isCaseMarkerTarget, isReaderlessCaseMarkerTarget };
