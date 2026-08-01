"use strict";
// Preload script for RV-REC regression tests.
// When required via `node --require ./hvsj-call-counter.js`, intercepts
// fs.writeFileSync calls targeting the atomic-write tmp file for one session
// (HVSJ_FAULT_SID) to (a) count how many times markStep attempts the write and
// (b) inject the fault itself by throwing EISDIR instead of writing. On process
// exit the count is written to HVSJ_COUNTER_FILE.
//
// #1733: writeStateLocked()'s tmp path is now `<sid>.json.<pid>.<counter>.tmp`
// (hooks/workflow-state/state-io/core.js), not the bare `<sid>.json.tmp` this
// preload originally matched -- a stray hand-created directory can no longer
// collide with it (that collision-proofing is itself the point of the pid+
// counter scheme). Fault injection therefore happens HERE, at the
// fs.writeFileSync layer, keyed on the session id embedded in the tmp path,
// rather than via a pre-created directory at a guessable path.
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
//   HVSJ_COUNTER_FILE=/tmp/count.txt HVSJ_FAULT_SID=rvrec1
//     node --require ./path/to/hvsj-call-counter.js ...

const fs = require("fs");

const counterFile = process.env.HVSJ_COUNTER_FILE;
if (!counterFile) {
  // Not activated -- no-op.
  module.exports = {};
  return;
}

const faultSid = process.env.HVSJ_FAULT_SID || "";

let tmpWriteAttempts = 0;

// Matches a tmp path belonging to the target session: "<sid>.json." appears
// as a path segment and the path ends in ".tmp". This mirrors the
// "<sid>.json.<pid>.<counter>.tmp" shape from writeStateLocked()
// (state-io/core.js), matched without a regex (avoids special-char escaping
// pitfalls for arbitrary session ids).
function isTargetTmpPath(fp) {
  if (!faultSid) return false;
  var marker = faultSid + ".json.";
  var idx = fp.lastIndexOf(marker);
  if (idx === -1) return false;
  var before = idx === 0 ? "" : fp.charAt(idx - 1);
  if (before !== "" && before !== "/" && before !== "\\") return false;
  return fp.slice(idx + marker.length).endsWith(".tmp");
}

const origWriteFileSync = fs.writeFileSync;
fs.writeFileSync = function (filePath, ...rest) {
  const fp = String(filePath);
  if (isTargetTmpPath(fp)) {
    tmpWriteAttempts++;
    const err = new Error("EISDIR: illegal operation on a directory, open '" + fp + "'");
    err.code = "EISDIR";
    throw err;
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
