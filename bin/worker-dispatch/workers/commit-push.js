"use strict";
// bin/worker-dispatch/workers/commit-push.js
//
// Stage 3 worker: replaces agents/commit-push-worker.md (#1673). Dispatch and
// re-export only — the implementation lives in the sibling commit-push/ folder
// (rules/coding/file-split.md Pattern A): procedure.js (the run() spine),
// gate.js (the D1 gate seam and the child-process helpers), push.js (step 7),
// pr.js (step 9). What/Why for all four:
// docs/architecture/claude-code/worker-dispatch/commit-push.md

const { isProtectedBranch, resolveGateEnv } = require("./commit-push/gate");
const { pushToRemote } = require("./commit-push/push");
const { run } = require("./commit-push/procedure");

module.exports = { run, resolveGateEnv, isProtectedBranch, pushToRemote };
