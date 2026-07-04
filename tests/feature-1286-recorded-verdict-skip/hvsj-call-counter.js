"use strict";
// Preload script for RV-REC regression tests.
// When required via `node --require ./hvsj-call-counter.js`, intercepts
// fs.writeFileSync calls targeting *.json.tmp paths to count how many times
// markStep attempts an atomic write.  On process exit it writes the count to
// HVSJ_COUNTER_FILE.
//
// The fixed code:   markStep is attempted exactly once per skip-judgment check.
//                   When it fails (EISDIR), computeVerdict is NOT re-entered,
//                   so the write is attempted once per invocation.
//
// The unfixed code: markStep fails (EISDIR), but computeVerdict is called
//                   unconditionally, so the write is attempted O(stack-depth)
//                   times (~5000+) before the RangeError is caught.
//
// Usage:
//   HVSJ_COUNTER_FILE=/tmp/count.txt node --require ./path/to/hvsj-call-counter.js ...

const fs = require("fs");

const counterFile = process.env.HVSJ_COUNTER_FILE;
if (!counterFile) {
  // Not activated — no-op.
  module.exports = {};
  return;
}

let tmpWriteAttempts = 0;

const origWriteFileSync = fs.writeFileSync;
fs.writeFileSync = function (filePath, ...rest) {
  const fp = String(filePath);
  if (fp.endsWith(".json.tmp")) {
    tmpWriteAttempts++;
  }
  return origWriteFileSync.apply(this, [filePath, ...rest]);
};

process.on("exit", () => {
  try {
    fs.writeFileSync = origWriteFileSync; // restore before writing counter
    origWriteFileSync.call(fs, counterFile, String(tmpWriteAttempts), "utf8");
  } catch (_) {}
});

module.exports = {};
