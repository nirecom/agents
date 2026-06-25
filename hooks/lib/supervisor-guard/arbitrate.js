"use strict";

// #720 — Alert / audit verdict arbitration.
// Pure rule table. Inputs are candidate objects of shape:
//   { verdict: "CONTINUE" | "WARN" | "BLOCK", reason: string }
// or null (mode did not produce a candidate this cycle).
// Output: { decision: "allow" | "warn" | "block", source: "l2"|"l3"|"both"|null, reason: string }
// BLOCK wins; WARN aggregates; otherwise allow.

function arbitrate(l2Candidate, l3Candidate) {
  const l2Block = l2Candidate && l2Candidate.verdict === "BLOCK";
  const l3Block = l3Candidate && l3Candidate.verdict === "BLOCK";

  if (l2Block && l3Block) {
    return {
      decision: "block",
      source: "both",
      reason: `${l3Candidate.reason}\n---\n${l2Candidate.reason}`,
    };
  }
  if (l3Block) return { decision: "block", source: "l3", reason: l3Candidate.reason };
  if (l2Block) return { decision: "block", source: "l2", reason: l2Candidate.reason };

  const l2Warn = l2Candidate && l2Candidate.verdict === "WARN";
  const l3Warn = l3Candidate && l3Candidate.verdict === "WARN";
  if (l2Warn && l3Warn) {
    return {
      decision: "warn",
      source: "both",
      reason: `${l3Candidate.reason}\n---\n${l2Candidate.reason}`,
    };
  }
  if (l3Warn) return { decision: "warn", source: "l3", reason: l3Candidate.reason };
  if (l2Warn) return { decision: "warn", source: "l2", reason: l2Candidate.reason };

  return { decision: "allow", source: null, reason: "" };
}

module.exports = { arbitrate };
