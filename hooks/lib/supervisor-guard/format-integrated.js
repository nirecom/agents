"use strict";

// #720 — Format the arbitrated L2/L3 verdict into a single block-reason string.
// Inputs:
//   arbitration       — result of arbitrate(l2, l3) (decision/source/reason).
//   formattedL2Reason — pre-formatted L2 reason from supervisor-report-format
//                       (may be null when no L2 candidate fired).
//   formattedL3Reason — pre-formatted L3 reason (may be null).
// Output: the final reason string. When both layers contributed, L3 is shown
// first (strategic context) followed by L2 (operational detail), separated by
// a horizontal rule.

function formatIntegratedReason(arbitration, formattedL2Reason, formattedL3Reason) {
  if (!arbitration || arbitration.decision === "allow") return "";
  const parts = [];
  if (arbitration.source === "both") {
    if (formattedL3Reason) parts.push(formattedL3Reason);
    if (formattedL2Reason) parts.push(formattedL2Reason);
  } else if (arbitration.source === "l3") {
    if (formattedL3Reason) parts.push(formattedL3Reason);
    else parts.push(arbitration.reason);
  } else if (arbitration.source === "l2") {
    if (formattedL2Reason) parts.push(formattedL2Reason);
    else parts.push(arbitration.reason);
  } else {
    parts.push(arbitration.reason);
  }
  return parts.filter(Boolean).join("\n---\n");
}

module.exports = { formatIntegratedReason };
