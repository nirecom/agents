"use strict";
// Tests: hooks/pre-commit.d/registry.js, hooks/pre-commit.d/orchestrator.js, hooks/pre-commit.d/output.js, hooks/pre-commit.d/snapshot.js, hooks/pre-commit.d/context.js, hooks/pre-commit.d/main.js, hooks/pre-commit.d/checks/enforce-worktree.js, hooks/pre-commit.d/checks/settings-effort-unstage.js, hooks/pre-commit.d/checks/code-lang.js, hooks/pre-commit.d/checks/sh-exec-bit.js, hooks/pre-commit.d/checks/env-file-block.js, hooks/pre-commit.d/checks/agents-repo-gates.js, hooks/pre-commit.d/checks/comment-block-size.js, hooks/pre-commit.d/checks/prompt-extraction.js, hooks/pre-commit.d/checks/repo-visibility.js
// Tags: TL1, pre-commit, pre-commit-node, registry, orchestrator, snapshot, repo-identity, real-git, commit-wiring, section-markers, scope:issue-specific, fail-closed
// #2507: the pre-commit body moves from bash into one Node process (hooks/pre-commit.d). These
// cases pin the registry declarations (D2), the orchestrator contract, the snapshot, the repo
// identity (D3) and each ported check's verdict and wording against the current bash hook.
// Each case's tests live in tests/hooks/feature-2507-precommit-node/*.js; F is their fixture surface,
// X the commit template whose cases make a real `git commit` through a copy of hooks/ and bin/.
// TL3 gap: the enforce-worktree TTY exemption and the warn-only "[y/N]" prompt read from /dev/tty
// need a real terminal; only the isTTY flag reaches them here, so a human `git commit` run is the
// one end-to-end check.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { makeFixtures } = require("./feature-2507-precommit-node/fixtures");
const { makeTemplate } = require("./feature-2507-precommit-node/commit-template");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2507-precommit-node-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

const F = makeFixtures(TMP, gitInit);
const reg = require("./feature-2507-precommit-node/registry-cases");
const orch = require("./feature-2507-precommit-node/orchestrator-cases");
const snap = require("./feature-2507-precommit-node/snapshot-context-cases");
const snapErr = require("./feature-2507-precommit-node/snapshot-spawn-error-cases");
const ew = require("./feature-2507-precommit-node/enforce-worktree-cases");
const basic = require("./feature-2507-precommit-node/basic-checks-cases");
const gates = require("./feature-2507-precommit-node/gate-cases");
const gateStaged = require("./feature-2507-precommit-node/gate-staged-cases");
const cp = require("./feature-2507-precommit-node/comment-prompt-cases");
const vm = require("./feature-2507-precommit-node/visibility-main-cases");
const mn = require("./feature-2507-precommit-node/merge-narrow-cases");
const X = makeTemplate(TMP, gitInit);
const flow = require("./feature-2507-precommit-node/commit-flow-cases");

caseBegin("registry-required-declarations", "hooks/pre-commit.d/registry.js");
reg.requiredDeclarations(F);
caseEnd();

caseBegin("registry-marker-order-and-gate-names", "hooks/pre-commit.d/registry.js");
reg.markerOrder(F);
caseEnd();

caseBegin("registry-visibility-order-and-read-source", "hooks/pre-commit.d/registry.js");
reg.visibilityAndReadSource(F);
caseEnd();

caseBegin("orchestrator-fail-mode-mapping", "hooks/pre-commit.d/orchestrator.js");
orch.failModeMapping(F);
caseEnd();

caseBegin("orchestrator-snapshot-rebuild-after-index-change", "hooks/pre-commit.d/orchestrator.js");
orch.snapshotRebuild(F);
caseEnd();

caseBegin("orchestrator-merge-narrowing", "hooks/pre-commit.d/orchestrator.js");
orch.mergeNarrowing(F);
caseEnd();

caseBegin("orchestrator-agents-repo-only-marker-only", "hooks/pre-commit.d/orchestrator.js");
orch.agentsRepoOnly(F);
caseEnd();

caseBegin("context-repo-identity", "hooks/pre-commit.d/context.js");
snap.repoIdentity(F);
caseEnd();

caseBegin("output-marker-before-check", "hooks/pre-commit.d/output.js");
orch.markerBeforeCheck(F);
caseEnd();

caseBegin("snapshot-head-batch-read", "hooks/pre-commit.d/snapshot.js");
snap.headBatchRead(F);
caseEnd();

caseBegin("snapshot-blob-read-fails-closed", "hooks/pre-commit.d/snapshot.js");
snap.blobReadFailsClosed(F);
caseEnd();

caseBegin("snapshot-cat-file-spawn-error-fails-closed", "hooks/pre-commit.d/snapshot.js");
snapErr.catFileSpawnError(F);
caseEnd();

caseBegin("snapshot-missing-blob-blocks-outbound-scan", "hooks/pre-commit.d/snapshot.js");
snap.missingBlobBlocksOutboundScan(F);
caseEnd();

caseBegin("check-enforce-worktree-bash-parity", "hooks/pre-commit.d/checks/enforce-worktree.js");
ew.enforceWorktree(F);
caseEnd();

caseBegin("check-settings-effort-unstage-bash-parity", "hooks/pre-commit.d/checks/settings-effort-unstage.js");
basic.settingsEffortUnstage(F);
caseEnd();

caseBegin("check-code-lang-bash-parity", "hooks/pre-commit.d/checks/code-lang.js");
basic.codeLang(F);
caseEnd();

caseBegin("check-sh-exec-bit-bash-parity", "hooks/pre-commit.d/checks/sh-exec-bit.js");
basic.shExecBit(F);
caseEnd();

caseBegin("check-env-file-block-bash-parity", "hooks/pre-commit.d/checks/env-file-block.js");
basic.envFileBlock(F);
caseEnd();

caseBegin("check-agents-repo-gates", "hooks/pre-commit.d/checks/agents-repo-gates.js");
gates.agentsRepoGates(F);
caseEnd();

caseBegin("check-agents-repo-gates-staged-reads", "hooks/pre-commit.d/checks/agents-repo-gates.js");
gateStaged.gateStagedReads(F);
caseEnd();

caseBegin("check-comment-block-size", "hooks/pre-commit.d/checks/comment-block-size.js");
cp.commentBlockSize(F);
caseEnd();

caseBegin("check-prompt-extraction", "hooks/pre-commit.d/checks/prompt-extraction.js");
cp.promptExtraction(F);
caseEnd();

caseBegin("merge-narrow-code-lang", "hooks/pre-commit.d/checks/code-lang.js");
mn.mergeNarrowCases(F, "code-lang");
caseEnd();

caseBegin("merge-narrow-sh-exec-bit", "hooks/pre-commit.d/checks/sh-exec-bit.js");
mn.mergeNarrowCases(F, "sh-exec-bit");
caseEnd();

caseBegin("merge-narrow-prompt-extraction", "hooks/pre-commit.d/checks/prompt-extraction.js");
mn.mergeNarrowCases(F, "prompt-extraction");
caseEnd();

caseBegin("merge-narrow-comment-block-size", "hooks/pre-commit.d/checks/comment-block-size.js");
mn.mergeNarrowCases(F, "comment-block-size");
caseEnd();

caseBegin("check-repo-visibility", "hooks/pre-commit.d/checks/repo-visibility.js");
vm.repoVisibility(F);
caseEnd();

caseBegin("main-rc-and-entry-contract", "hooks/pre-commit.d/main.js");
vm.mainEntry(F);
caseEnd();

caseBegin("commit-clean-marker-sequence", "hooks/pre-commit.d/registry.js");
flow.cleanSequence(X);
caseEnd();

caseBegin("commit-blocking-section-wording-and-stop-point", "hooks/pre-commit.d/orchestrator.js");
flow.blockingSections(X);
caseEnd();

caseBegin("commit-test-file-gates-case-marker-and-language-match", "hooks/pre-commit.d/orchestrator.js");
flow.testFileGates(X);
caseEnd();

caseBegin("commit-foreign-repo-global-hooks-path", "hooks/pre-commit.d/main.js");
flow.foreignRepo(X);
caseEnd();

caseBegin("commit-non-github-origin-ends-at-repo-visibility", "hooks/pre-commit.d/main.js");
flow.nonGithubOrigin(X);
caseEnd();
