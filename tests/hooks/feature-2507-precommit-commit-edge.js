"use strict";
// Tests: hooks/pre-commit, hooks/pre-commit.d/main.js, hooks/pre-commit.d/orchestrator.js
// Tags: TL2, pre-commit, pre-commit-node, real-git, commit-wiring, test-lang-exception:e2e, scope:issue-specific
// #2507: the edge paths of a real `git commit` through the pre-commit hook — node absent, no TTY,
// an initial commit, binary and empty files, a merge commit, a new test missing a frontmatter
// line, a commit of named paths and the
// .env-over-ambient COMMENT_BLOCK_ENFORCE precedence. Kept apart from
// tests/hooks/feature-2507-precommit-node.js (whose commit template it reuses) so each file stays
// inside the per-file time budget. That file's header holds the TL3 gap.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { makeTemplate } = require("./feature-2507-precommit-node/commit-template");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2507-precommit-edge-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

const X = makeTemplate(TMP, gitInit);
const edge = require("./feature-2507-precommit-commit-edge/edge-cases");

caseBegin("commit-node-missing-fails-closed", "hooks/pre-commit");
edge.nodeMissing(X);
caseEnd();

caseBegin("commit-warn-only-no-tty-auto-block", "hooks/pre-commit.d/main.js");
edge.warnNoTty(X);
caseEnd();

caseBegin("commit-initial-commit-scan-and-env-block", "hooks/pre-commit.d/main.js");
edge.initialCommit(X);
caseEnd();

caseBegin("commit-binary-and-empty-not-scanned", "hooks/pre-commit.d/main.js");
edge.binaryAndEmpty(X);
caseEnd();

caseBegin("commit-merge-narrowing", "hooks/pre-commit.d/orchestrator.js");
edge.mergeNarrowing(X);
caseEnd();

caseBegin("commit-tests-frontmatter-missing-line", "hooks/pre-commit.d/orchestrator.js");
edge.frontmatterMissing(X);
caseEnd();

caseBegin("commit-paths-temporary-index", "hooks/pre-commit.d/main.js");
edge.pathCommit(X);
caseEnd();

caseBegin("commit-comment-block-enforce-env-beats-ambient", "hooks/pre-commit.d/main.js");
edge.commentBlockEnvPrecedence(X);
caseEnd();

caseBegin("commit-merge-incoming-only-code-lang", "hooks/pre-commit.d/main.js");
edge.mergeIncomingOnly(X, "code-lang");
caseEnd();

caseBegin("commit-merge-incoming-only-prompt-extraction", "hooks/pre-commit.d/main.js");
edge.mergeIncomingOnly(X, "prompt-extraction");
caseEnd();

caseBegin("commit-merge-incoming-only-comment-block-size", "hooks/pre-commit.d/main.js");
edge.mergeIncomingOnly(X, "comment-block-size");
caseEnd();
