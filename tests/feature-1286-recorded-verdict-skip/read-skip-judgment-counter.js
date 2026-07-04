"use strict";
// Preload script for RV-36 single-read regression test.
// When required via `node --require ./read-skip-judgment-counter.js`, intercepts
// the `readSkipJudgment` function that next-step's applyRecordedVerdictSkip helper
// will import after hardening #3/#7.
//
// Wrapping strategy:
//   The helper may import readSkipJudgment from either of two paths:
//     (A) hooks/lib/workflow-state.js        (dispatch/re-export module)
//     (B) hooks/lib/workflow-state/skip-signal-resolver.js  (underlying resolver)
//   To guarantee interception regardless of which path the helper uses, this
//   preload wraps readSkipJudgment on BOTH module exports against a SHARED counter.
//
//   Both wrappers increment the same counter; because the helper uses exactly ONE
//   import path at runtime, exactly one wrapper fires per call — no double-counting.
//   Each wrapper captures its own `orig` and calls only that orig (not the other
//   wrapper), so there is no cross-calling chain.
//
//   workflow-state.js does: module.exports = { ...skipSignalResolver }
//   The spread copies function references. We patch each module's exported
//   readSkipJudgment independently so the destructure in next-step picks up
//   whichever wrapper applies to its import path.
//
//   NOTE: pre-hardening next-step calls hasValidSkipJudgment (not readSkipJudgment
//   directly), so count will be 0 pre-hardening. Post-hardening count == 1 means
//   applyRecordedVerdictSkip does a single read. The test asserts count == 1.
//
// Usage:
//   RSJ_COUNTER_FILE=/tmp/rsj-count.txt node --require ./path/to/read-skip-judgment-counter.js ...

const path = require("path");

const counterFile = process.env.RSJ_COUNTER_FILE;
if (!counterFile) {
  // Not activated — no-op.
  module.exports = {};
  return;
}

let readSkipJudgmentCallCount = 0;

// Resolve module paths from this file's location.
// this file: tests/feature-1286-recorded-verdict-skip/read-skip-judgment-counter.js
// AGENTS_DIR is two levels up.
const AGENTS_DIR = path.resolve(__dirname, "..", "..");
const workflowStatePath = path.join(AGENTS_DIR, "hooks", "lib", "workflow-state.js");
const skipSignalResolverPath = path.join(
  AGENTS_DIR, "hooks", "lib", "workflow-state", "skip-signal-resolver.js"
);

// Wrap the dispatch/re-export module (hooks/lib/workflow-state.js).
try {
  // Force-load the module so it's in cache before next-step requires it.
  const wfState = require(workflowStatePath);
  const origReadSkipJudgment = wfState.readSkipJudgment;
  if (typeof origReadSkipJudgment === "function") {
    wfState.readSkipJudgment = function (...args) {
      readSkipJudgmentCallCount++;
      return origReadSkipJudgment.apply(this, args);
    };
  }
} catch (_) {
  // Module not available — counter stays at 0.
}

// Wrap the underlying resolver module (hooks/lib/workflow-state/skip-signal-resolver.js).
// This ensures interception when the helper imports directly from the resolver rather
// than from the dispatch module. Each wrapper has its own captured `orig` and calls
// only that orig — no cross-calling, no double-counting.
try {
  const resolver = require(skipSignalResolverPath);
  const origReadSkipJudgment = resolver.readSkipJudgment;
  if (typeof origReadSkipJudgment === "function") {
    resolver.readSkipJudgment = function (...args) {
      readSkipJudgmentCallCount++;
      return origReadSkipJudgment.apply(this, args);
    };
  }
} catch (_) {
  // Module not available — counter stays at 0.
}

const fs = require("fs");
process.on("exit", () => {
  try {
    fs.writeFileSync(counterFile, String(readSkipJudgmentCallCount), "utf8");
  } catch (_) {}
});

module.exports = {};
