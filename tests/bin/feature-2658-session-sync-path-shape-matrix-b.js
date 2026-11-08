"use strict";
// Tests: bin/lib/session-sync/classify.js
// Tags: TL2, session-sync, session-sync-engine, path-shape, real-git, two-clone, scope:issue-specific
// #2658: the remote adds a file where local main has a directory, in both run orders and pull-only.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");
const { pathShapeMatrix } = require("./feature-2658-session-sync-path-shape/matrix");
const { pullOnly } = require("./feature-2658-session-sync-path-shape/scenarios");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-path-shape-matrix-b-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

caseBegin("e2e-remote-file-over-local-directory-matrix", "bin/lib/session-sync/classify.js");
pathShapeMatrix(F, "b");
caseEnd();

caseBegin("e2e-pull-only-collision", "bin/lib/session-sync/classify.js");
pullOnly(F);
caseEnd();
