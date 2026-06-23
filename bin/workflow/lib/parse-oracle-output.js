"use strict";

// parseOracleOutput(stdout) -> { ACTION, NEXT_SKILL, NEXT_HINT, REASON }
// Handles both KEY='value' and KEY=value forms.
// Oracle invariant: no single-quote chars in values -> safe single-quote parse.

const LINE_RE = /^(\w+)=(?:'([^']*)'|(.*))$/;
const REQUIRED_KEYS = ["ACTION", "NEXT_SKILL", "NEXT_HINT", "REASON"];

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
  };
}

function malformed() {
  return { ACTION: "abort", NEXT_SKILL: "", NEXT_HINT: "", REASON: "oracle-output-malformed" };
}

module.exports = { parseOracleOutput };
