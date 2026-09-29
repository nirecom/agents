"use strict";

// The argv walk itself lives in hooks/lib/gh-api-argv.js (SSOT, shared with the bash-guard
// read-only class); this module keeps the forge-ownership views built on top of it.
const { isGhApiWriteFromFlags } = require("../lib/forge-write-extract");
const {
  scanGhApiFlags,
  hasInputFlag,
  PAYLOAD_FIELD_FLAGS,
  GH_API_VALUE_FLAGS,
  GH_API_BOOL_FLAGS,
} = require("../lib/gh-api-argv");

function isGhApiWriteArgv(argv) {
  const scan = scanGhApiFlags(argv);
  if (scan.ambiguous) return true;
  return isGhApiWriteFromFlags(scan.flags);
}

function extractApiEndpoint(argv) {
  return scanGhApiFlags(argv).endpoint;
}

// The effective value of a repeated payload field, pflag-style: last wins.
function lastFieldValue(flags, fieldName) {
  let found = null;
  for (const f of flags) {
    if (!f || !PAYLOAD_FIELD_FLAGS.has(f.flag)) continue;
    if (typeof f.value !== "string") { found = { name: fieldName, value: null, raw: f.raw }; continue; }
    const eq = f.value.indexOf("=");
    if (eq < 0) continue;
    if (f.value.slice(0, eq) !== fieldName) continue;
    found = { name: fieldName, value: f.value.slice(eq + 1), raw: f.raw };
  }
  return found;
}

module.exports = {
  scanGhApiFlags,
  isGhApiWriteArgv,
  extractApiEndpoint,
  lastFieldValue,
  hasInputFlag,
  GH_API_VALUE_FLAGS,
  GH_API_BOOL_FLAGS,
  PAYLOAD_FIELD_FLAGS,
};
