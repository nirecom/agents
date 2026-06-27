"use strict";

// parseOracleOutput(stdout) -> { ACTION, NEXT_SKILL, NEXT_HINT, REASON }
// Handles both KEY='value' and KEY=value forms.
// Oracle invariant: no single-quote chars in values -> safe single-quote parse.

const LINE_RE = /^(\w+)=(?:'([^']*)'|(.*))$/;
const REQUIRED_KEYS = ["ACTION", "NEXT_SKILL", "NEXT_HINT", "REASON"];
// Optional keys (#485): present only when the oracle emits them. SKIP_HINT is an
// advisory plan-skip hint at the outline/detail steps; absent on every other
// step. Kept out of REQUIRED_KEYS so the legacy 4-line oracle output still parses.
const OPTIONAL_KEYS = ["SKIP_HINT"];

function parseOracleOutput(stdout) {
  const result = {};
  if (typeof stdout !== "string") {
    return malformed();
  }
  const lines = stdout.split(/\r?\n/);
  for (const line of lines) {
    if (line.length === 0) continue;
    const m = line.match(LINE_RE);
    if (!m) continue;
    const key = m[1];
    const value = m[2] !== undefined ? m[2] : (m[3] !== undefined ? m[3] : "");
    result[key] = value;
  }
  for (const k of REQUIRED_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(result, k)) {
      return malformed();
    }
  }
  if (result.ACTION === "") {
    return malformed();
  }
  return {
    ACTION: result.ACTION,
    NEXT_SKILL: result.NEXT_SKILL,
    NEXT_HINT: result.NEXT_HINT,
    REASON: result.REASON,
    SKIP_HINT: result.SKIP_HINT !== undefined ? result.SKIP_HINT : "",
  };
}

function malformed() {
  return { ACTION: "abort", NEXT_SKILL: "", NEXT_HINT: "", REASON: "oracle-output-malformed", SKIP_HINT: "" };
}

module.exports = { parseOracleOutput, REQUIRED_KEYS, OPTIONAL_KEYS };
