"use strict";
// A-4 speculative-skip verdict lifecycle (#1681).
//
// Re-export only. The implementation lives in ./state-io/skip-verdict.js, which is
// the same module the state-io barrel exposes — two copies of this lifecycle would
// be two places to fix a bug (CPR-2).

const {
  recordSkipVerdict,
  readSkipVerdict,
  hasSpeculativeSkipPending,
} = require("./state-io/skip-verdict");

module.exports = { recordSkipVerdict, readSkipVerdict, hasSpeculativeSkipPending };
