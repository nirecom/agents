"use strict";

// Pure functions over the supervisor state object's layer2.findings array.
// No fs, no requires of the writer — the caller is responsible for persistence.
// Status values: "draft" | "confirmed". A missing status is treated as "confirmed"
// by readers (backward compat) but never assigned implicitly here.

function getLayer2Findings(state) {
  if (!state || typeof state !== "object") return null;
  if (!state.layer2 || typeof state.layer2 !== "object" || Array.isArray(state.layer2)) return null;
  if (!Array.isArray(state.layer2.findings)) return null;
  return state.layer2.findings;
}

function appendDraftFinding(state, finding) {
  const findings = getLayer2Findings(state);
  if (!findings) return state;
  if (!finding || typeof finding !== "object") return state;
  // Use max existing idx + 1 so drops never create duplicate idx values.
  const maxIdx = findings.reduce((m, f) => (f && typeof f.idx === "number" ? Math.max(m, f.idx) : m), -1);
  const idx = maxIdx + 1;
  findings.push({ ...finding, idx, status: "draft" });
  return state;
}

function confirmFinding(state, idx) {
  const findings = getLayer2Findings(state);
  if (!findings) return state;
  for (const f of findings) {
    if (f && f.idx === idx) {
      f.status = "confirmed";
      return state;
    }
  }
  return state;
}

function dropFindings(state, idxList) {
  const findings = getLayer2Findings(state);
  if (!findings) return state;
  if (!Array.isArray(idxList) || idxList.length === 0) return state;

  // Deduplicate and sort descending so splice indices remain stable.
  const targets = [...new Set(idxList.filter((n) => Number.isInteger(n)))].sort((a, b) => b - a);

  for (const targetIdx of targets) {
    for (let i = findings.length - 1; i >= 0; i--) {
      if (findings[i] && findings[i].idx === targetIdx) {
        findings.splice(i, 1);
        break;
      }
    }
  }
  return state;
}

function promotePendingDraftsToConfirmed(state) {
  const findings = getLayer2Findings(state);
  if (!findings) return state;
  for (const f of findings) {
    if (f && f.status === "draft") f.status = "confirmed";
  }
  return state;
}

module.exports = {
  appendDraftFinding,
  confirmFinding,
  dropFindings,
  promotePendingDraftsToConfirmed,
};
