"use strict";
// Tests: hooks/lib/merge-parents.js, hooks/lib/merge-state.js, hooks/lib/merge-incoming.js, bin/merge-parents
// Tags: TL2, hooks, merge, merge-parents, merge-incoming, tests-gates, scope:issue-specific
// #2812: the parent(s) each staged path is judged against during a merge (D2 rules R1-R7, content
// only), the bin/merge-parents record stream, and the #2761 detectMergeIncoming contract.
// Case bodies and fixtures: ./feat-2812-merge-parents/.
// TL3 gap (what this test does NOT catch):
// - a real merge `git commit` through the installed pre-commit hook binary.
// (sha256 repos: covered through the CLI and the bash reader by tests/bin/feat-2812-tests-gates-merge/nul-paths.sh.)
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-transcripts-"));
for (const name of ["CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]) delete process.env[name];
process.chdir(os.tmpdir());

const X = require("./feat-2812-merge-parents/fixture");
const R = require("./feat-2812-merge-parents/rule-cases");
const K = require("./feat-2812-merge-parents/cli-contract-cases");
const W = require("./feat-2812-merge-parents/worktree-cases");
// One test per case: it fails when any X.check inside it (or an exception, via guarded) adds a failure.
const g = (label, fn) => test(label, () => noNewFailures(X.failureCount, () => X.guarded(label, fn)));
after(() => {
  restoreIsolation();
  X.finish();
});

caseBegin("R1 staged blob equal to a parent is existing", "hooks/lib/merge-parents.js");
g("R1", R.R1);
caseEnd();

caseBegin("R1 holds on a path both parents carry with different blobs", "hooks/lib/merge-parents.js");
g("R1-shared", R.R1shared);
caseEnd();

caseBegin("R2 path in neither parent is new", "hooks/lib/merge-parents.js");
g("R2", R.R2);
caseEnd();

caseBegin("R3 path only in HEAD uses the HEAD blob", "hooks/lib/merge-parents.js");
g("R3", R.R3);
caseEnd();

caseBegin("R4 path only in MERGE_HEAD uses the MERGE_HEAD blob", "hooks/lib/merge-parents.js");
g("R4", R.R4);
caseEnd();

caseBegin("R5 identical parents use one blob with or without a merge-base blob", "hooks/lib/merge-parents.js");
g("R5", R.R5);
caseEnd();

caseBegin("R6 differing parents with a unique merge-base go 3-way", "hooks/lib/merge-parents.js");
g("R6", R.R6);
caseEnd();

caseBegin("R7 differing parents in a criss-cross fall back to HEAD while R5 stays R5", "hooks/lib/merge-parents.js");
g("R7", R.R7);
caseEnd();

caseBegin("only R1-R5 paths never run git merge-base", "hooks/lib/merge-parents.js");
g("lazy-merge-base", R.lazy);
caseEnd();

caseBegin("mode-only difference still counts as the same content", "hooks/lib/merge-parents.js");
g("mode", R.mode);
caseEnd();

caseBegin("octopus and unreadable MERGE_HEAD tree judge against HEAD only", "hooks/lib/merge-parents.js");
g("fallback", R.fallback);
caseEnd();

caseBegin("outside a merge only HEAD is a parent", "hooks/lib/merge-parents.js");
g("not-merging", R.notMerging);
caseEnd();

caseBegin("GIT_INDEX_FILE selects the index whose oids are compared", "hooks/lib/merge-parents.js");
g("index-file", R.indexFile);
caseEnd();

caseBegin("unreadable index or HEAD tree returns ok false", "hooks/lib/merge-parents.js");
g("ok-false", R.okFalse);
caseEnd();

caseBegin("index git cannot parse or a missing HEAD tree gives tree-unreadable and CLI exit 2", "hooks/lib/merge-parents.js");
g("tree-unreadable", R.treeUnreadable);
caseEnd();

caseBegin("merge inside a linked worktree resolves the per-worktree MERGE_HEAD", "hooks/lib/merge-parents.js");
g("worktree-r4", W.worktreeR4);
caseEnd();

caseBegin("detectMergeIncoming reads the per-worktree MERGE_HEAD", "hooks/lib/merge-incoming.js");
g("worktree-detect", W.worktreeDetect);
caseEnd();

caseBegin("CLI record stream carries header, placeholders and raw paths", "bin/merge-parents");
g("cli-format", K.cliFormat);
caseEnd();

caseBegin("CLI writes all five fields for a 3-way path and names an undecidable reason", "bin/merge-parents");
g("cli-merge", K.cliMerge);
caseEnd();

caseBegin("CLI exits 2 on a usage error or an unresolvable repo", "bin/merge-parents");
g("cli-exit2", K.cliExit2);
caseEnd();

caseBegin("readMergeState names the same states and reasons as before", "hooks/lib/merge-state.js");
g("merge-state", K.mergeState);
caseEnd();

caseBegin("detectMergeIncoming keeps its states, reasons and order", "hooks/lib/merge-incoming.js");
g("contract-reasons", K.contractReasons);
caseEnd();

caseBegin("detectMergeIncoming paths still need blob and mode to match", "hooks/lib/merge-incoming.js");
g("contract-paths", K.contractPaths);
caseEnd();

caseBegin("MERGE_INCOMING_STATE is the MERGE_STATE object", "hooks/lib/merge-incoming.js");
g("contract-identity", K.contractIdentity);
caseEnd();
