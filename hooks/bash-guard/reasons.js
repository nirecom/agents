"use strict";
// hooks/bash-guard/reasons.js — frozen reason-code registry for bash-guard.
//
// The BG- namespace is disjoint from workflow-gate's T-A..T-E tiers (#2012): a shared
// code would make one string mean two things in a transcript, and #2122's measurement
// denominator must not mix the two populations.
// REASON_CODES holds exactly the deny codes — one per forbidden-literal id, so the
// registry's size is a direct check on the approved set. The allow-side attributions
// below are a separate export for that reason; they explain silence, not a denial.

const { LITERAL_IDS } = require("./forbidden-literals");

const codeFor = (literalId) => "BG-" + literalId.toUpperCase();

const REASON_CODES = Object.freeze(LITERAL_IDS.map(codeFor));

// Why the guard stayed quiet. Not deny codes, so deliberately not in REASON_CODES.
const ALLOW_CODES = Object.freeze({
  TOOL_OUT_OF_SCOPE: "BG-TOOL-OUT-OF-SCOPE",
  INTERLOCK_QUIET: "BG-INTERLOCK-QUIET",
  ALLOW_RULE: "BG-ALLOW-RULE",
  PARSE_FAILURE: "BG-PARSE-FAILURE",
  NO_HIT: "BG-NO-HIT",
});

/**
 * @param {string} literalId a forbidden-literals.js id
 * @returns {string|null} the declared deny code, or null for an unknown id
 */
function reasonCodeFor(literalId) {
  if (!LITERAL_IDS.includes(literalId)) return null;
  return codeFor(literalId);
}

module.exports = { REASON_CODES, ALLOW_CODES, reasonCodeFor };
