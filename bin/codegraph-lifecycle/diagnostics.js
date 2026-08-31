#!/usr/bin/env node
// diagnostics.js — the two output channels every codegraph-lifecycle module
// shares, and the sole owner of the line prefix (CPR-SSOT).
//
// warn is one stderr line: something a person may want to know, never a
// failure the caller must handle. report is one stdout line and is reserved
// for a state change that actually happened, which is what lets a caller
// treat any stdout at all as "something was done".

process.removeAllListeners("warning");

const PREFIX = "codegraph-lifecycle: ";

function warn(message) {
  process.stderr.write(PREFIX + message + "\n");
}

function report(message) {
  process.stdout.write(PREFIX + message + "\n");
}

module.exports = { warn, report };
