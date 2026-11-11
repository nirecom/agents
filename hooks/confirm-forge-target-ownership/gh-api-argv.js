"use strict";

// The argv walk itself lives in hooks/lib/gh-api-argv.js (SSOT, shared with the bash-guard
// read-only class); this module keeps the forge-ownership views built on top of it.
const { isGhApiWriteFromFlags } = require("../lib/forge-write-extract");
const {
  scanGhApiFlags,
  hasInputFlag,
  lastFieldValue,
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
