"use strict";
// Tests: hooks/lib/test-gates/git-blobs.js, bin/check-test-frontmatter/cli.js
// Tags: TL2, hooks, bin, test-gates, git-blobs, check-test-frontmatter, cat-file, real-git, fail-closed, table-driven, scope:issue-specific
// #2507: blobs() of the test-gate CLIs reads staged and HEAD blobs through one real
// `git cat-file --batch`. A missing object, a tree reply and a newline name are sanctioned and
// leave the name out; every other gap (spawn error, non-zero, signal, truncated or malformed
// reply) must throw, and check-test-frontmatter --staged must turn that throw into rc 2.
// Failures are injected by patching child_process.spawnSync (fixture.js withCatFile).
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { makeFixtures } = require("./feature-2507-git-blobs-fail-closed/fixture");
const B = require("./feature-2507-git-blobs-fail-closed/blobs-cases");
const C = require("./feature-2507-git-blobs-fail-closed/cli-cases");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2507-git-blobs-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

const F = makeFixtures(TMP, gitInit);

caseBegin("blobs-reads-staged-head-empty-nul-duplicate-newline", "hooks/lib/test-gates/git-blobs.js");
B.readsBlobs(F);
caseEnd();

caseBegin("blobs-missing-and-tree-replies-are-not-failures", "hooks/lib/test-gates/git-blobs.js");
B.missingAndTree(F);
caseEnd();

caseBegin("blobs-failed-or-malformed-batch-throws", "hooks/lib/test-gates/git-blobs.js");
B.failsClosed(F);
caseEnd();

caseBegin("frontmatter-staged-reads-staged-and-head-blobs", "bin/check-test-frontmatter/cli.js");
C.stagedReads(F);
caseEnd();

caseBegin("frontmatter-staged-cat-file-failure-ends-rc-2", "bin/check-test-frontmatter/cli.js");
C.stagedFailsClosed(F);
caseEnd();
