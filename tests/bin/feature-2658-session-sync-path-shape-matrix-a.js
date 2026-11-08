"use strict";
// Tests: bin/lib/session-sync/classify.js
// Tags: TL2, session-sync, session-sync-engine, path-shape, real-git, two-clone, scope:issue-specific
// #2658: a file replaced by a directory on one machine, run through the real engine in each order.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");
const { pathShapeMatrix } = require("./feature-2658-session-sync-path-shape/matrix");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-path-shape-matrix-a-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

caseBegin("e2e-file-replaced-by-directory-matrix", "bin/lib/session-sync/classify.js");
pathShapeMatrix(F, "a");
caseEnd();
