"use strict";
// Tests: bin/lib/session-sync/classify.js, bin/lib/session-sync/cli.js, bin/lib/session-sync/plans.js
// Tags: TL2, session-sync, session-sync-engine, path-shape, real-git, two-clone, scope:issue-specific, write-blocked
// #2658: reset in both shapes, the blocking file a machine keeps, the status line, plans as a file.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");
const { resetShapes, residualBehaviour, plansThroughEngine } = require("./feature-2658-session-sync-path-shape/scenarios");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-path-shape-residual-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

caseBegin("e2e-reset-both-shapes", "bin/lib/session-sync/classify.js");
resetShapes(F);
caseEnd();

caseBegin("e2e-blocking-file-residual-behaviour-and-status-line", "bin/lib/session-sync/cli.js");
residualBehaviour(F);
caseEnd();

caseBegin("e2e-plans-as-a-file", "bin/lib/session-sync/plans.js");
plansThroughEngine(F);
caseEnd();
