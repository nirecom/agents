"use strict";
// hooks/bash-guard/reasons.js — frozen reason-code registries for bash-guard.
//
// The BG- namespace is disjoint from workflow-gate's T-A..T-E tiers (#2012): a shared
// code would make one string mean two things in a transcript, and #2122's measurement
// denominator must not mix the two populations.
// REASON_CODES holds exactly the deny codes — one per forbidden-literal id, so the
// registry's size is a direct check on the approved set. The three non-deny verdicts
// (passThrough, notify, allow) each own a separate registry for that reason.

const { LITERAL_IDS } = require("./forbidden-literals");

const codeFor = (literalId) => "BG-" + literalId.toUpperCase();

const REASON_CODES = Object.freeze(LITERAL_IDS.map(codeFor));

const PASS_THROUGH_CODES = Object.freeze({
  TOOL_OUT_OF_SCOPE: "BG-TOOL-OUT-OF-SCOPE",
  INTERLOCK_QUIET: "BG-INTERLOCK-QUIET",
  PARSE_FAILURE: "BG-PARSE-FAILURE",
  NO_HIT: "BG-NO-HIT",
});

const NOTIFY_CODES = Object.freeze({
  SENTINEL_NO_ECHO: "BG-NOTIFY-SENTINEL-NO-ECHO",
  SENTINEL_UNRECOGNIZED: "BG-NOTIFY-SENTINEL-UNRECOGNIZED",
  SCRIPT_NO_INTERPRETER: "BG-NOTIFY-SCRIPT-NO-INTERPRETER",
});

const ALLOW_CODES = Object.freeze({
  SELF_SCRIPT: "BG-ALLOW-SELF-SCRIPT",
  SELF_BARE: "BG-ALLOW-SELF-BARE",
});

/**
 * @param {string} literalId a forbidden-literals.js id
 * @returns {string|null} the declared deny code, or null for an unknown id
 */
function reasonCodeFor(literalId) {
  if (!LITERAL_IDS.includes(literalId)) return null;
  return codeFor(literalId);
}

module.exports = { REASON_CODES, PASS_THROUGH_CODES, NOTIFY_CODES, ALLOW_CODES, reasonCodeFor };
