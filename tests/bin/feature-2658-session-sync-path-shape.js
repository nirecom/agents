"use strict";
// Tests: bin/lib/session-sync/classify.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/plans.js, bin/lib/session-sync/state.js
// Tags: TL1, session-sync, session-sync-engine, path-shape, scope:issue-specific, write-blocked
// #2658: the units that carry the file-versus-directory fix. The real-engine cases are the sibling
// feature-2658-session-sync-path-shape-{matrix-a,matrix-b,residual}.js files.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");
const units = require("./feature-2658-session-sync-path-shape/units");
const unitsPlans = require("./feature-2658-session-sync-path-shape/units-plans-state");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-path-shape-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

caseBegin("collision-copy-name-table", "bin/lib/session-sync/conflict.js");
units.collisionCopyNameTable(F);
caseEnd();

caseBegin("path-blocked-table", "bin/lib/session-sync/apply.js");
units.pathBlockedTable(F);
caseEnd();

caseBegin("apply-ops-blocked-write-guard", "bin/lib/session-sync/apply.js");
units.applyOpsGuard(F);
caseEnd();

caseBegin("classify-resolve-path-collisions", "bin/lib/session-sync/classify.js");
units.classifyPostPass(F);
caseEnd();

caseBegin("plans-path-shape-guards", "bin/lib/session-sync/plans.js");
unitsPlans.plansGuards(F);
caseEnd();

caseBegin("state-write-blocked-counter", "bin/lib/session-sync/state.js");
unitsPlans.writeBlockedState(F);
caseEnd();
