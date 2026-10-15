"use strict";
// The shared "this switch is off" vocabulary (#2527 4-2). Lowercased, never
// trimmed: a whitespace-padded value is unknown, so it reads as not-off and the
// switch keeps its fail-safe default.

const OFF_VALUES = Object.freeze(["off", "0", "false", "no", "disabled"]);

function isOffValue(v) {
  if (typeof v !== "string") return false;
  return OFF_VALUES.includes(v.toLowerCase());
}

module.exports = { OFF_VALUES, isOffValue };
