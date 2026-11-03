"use strict";
// Tests: hooks/workflow-mark/reset-handler.js, hooks/workflow-state/review-tests-reopen.js, hooks/workflow-state/effective-state.js, hooks/workflow-state/record-step-verdict.js
// Tags: TL2, hooks, posttooluse, sentinel, reset-from, push-branch, review-tests, scope:issue-specific
// #2902 / #2824 Step 4: RESET_FROM_push_branch on a session whose push_branch is complete. The
// reset is applied to the record (reproduced: silent today), so the gap is the read side: while
// the PR head equals HEAD the network evidence reads push_branch complete again. The hook must say
// so as INFO (a re-push needs a new commit); a non-network step's reset must not. The reopen gate
// is pinned: the reset and recorded-verdict gates never reopen review_tests.
// TL3 gap (what this test does NOT catch):
// - the network evidence itself (PR head == HEAD via the forge): only the offline reconcile is
//   read here, so the read-time return to complete is described, not reproduced.
const { caseBegin, caseEnd, gitInit, isolate } = require("../lib/harness");
// lang-check: ignore — the regex below matches the Japanese output of the hook under test.

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const X = require("./feature-2824-sentinel-refusal-output/fixture").make();
const O = require("../lib/workflow-mark-output");
const ROOT = path.resolve(__dirname, "..", "..");
after(() => { X.cleanup(); restore(); });

const R = (step) => `echo "<<WORKFLOW_RESET_FROM_${step}: re-push after a fix>>"`;
const NEW_COMMIT = /new commit|新しい ?commit/i;
const recorded = (sid, step) => ((X.F.S.readState(sid) || {}).steps || {})[step] || {};

function pushedSession(tag) {
  const sid = X.F.seedWf(tag, ["clarify_intent", "outline", "detail"]);
  X.F.S.markStep(sid, "push_branch", "complete");
  assert.strictEqual(recorded(sid, "push_branch").status, "complete", "fixture: push_branch recorded complete");
  return sid;
}

caseBegin("push-branch-reset", "hooks/workflow-mark/reset-handler.js");
test("RESET_FROM_push_branch is applied to the record and the offline reconcile reads it pending", () => {
  const sid = pushedSession("pb-rec");
  X.mark(sid, R("push_branch"));
  assert.strictEqual(recorded(sid, "push_branch").status, "pending", "push_branch recorded pending");
  assert.strictEqual(X.F.events(sid, "reset").length, 1, "one reset event");
  const { reconcileEffectiveState } = require(path.join(ROOT, "hooks", "workflow-state", "effective-state.js"));
  const eff = reconcileEffectiveState(X.F.S.readState(sid), sid, {});
  assert.strictEqual(eff.steps.push_branch.status, "pending", JSON.stringify(eff.steps.push_branch));
});

test("RESET_FROM_push_branch tells, as INFO, that a re-push needs a new commit", () => {
  const sid = pushedSession("pb-info");
  const r = X.mark(sid, R("push_branch"));
  const why = O.infoFailure(r, /push_branch/);
  assert.strictEqual(why, null, why || "");
  const text = O.additionalContextOf(O.parseStdout(r.stdout));
  assert.match(text, NEW_COMMIT, `names the new-commit requirement: ${text}`);
});

test("a reset of a non-network step does not carry the new-commit note", () => {
  const sid = X.F.seedWf("pb-wc", ["clarify_intent", "outline", "detail"]);
  const r = X.mark(sid, R("write_code"));
  const why = O.infoFailure(r, /write_code/);
  assert.strictEqual(why, null, why || "");
  assert.doesNotMatch(O.additionalContextOf(O.parseStdout(r.stdout)), NEW_COMMIT);
});
caseEnd();

// staleReviewSession(tag) -> {sid, repo}: review_tests complete with a recorded scope that no longer
// matches the repo's staged test, so a reopening gate does reopen it (the control below).
function staleReviewSession(tag) {
  const repo = path.join(X.TMP, `${tag}-repo`).replace(/\\/g, "/");
  gitInit(repo);
  fs.mkdirSync(path.join(repo, "tests"));
  fs.writeFileSync(path.join(repo, "tests", "x.sh"), "echo x\n");
  const g = spawnSync("git", ["-C", repo, "add", "--", "tests/x.sh"], { encoding: "utf8", timeout: 30000 });
  assert.strictEqual(g.status, 0, `fixture: git add: ${g.stderr}`);
  const sid = X.nextSid(tag);
  const steps = {};
  for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests"]) steps[s] = { status: "complete" };
  steps.review_tests = { status: "complete", review_scope_manifest: { v: 1, files: { "tests/x.sh": "0".repeat(40) } } };
  for (const s of ["write_code", "run_tests", "review_security", "docs", "review_docs", "user_verification", "cleanup", "pre_final_report_gate", "final_report"]) {
    steps[s] = { status: "pending" };
  }
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`), JSON.stringify({ version: 1, session_id: sid, steps }));
  assert.strictEqual(recorded(sid, "review_tests").status, "complete", "fixture: review_tests recorded complete");
  return { sid, repo };
}

caseBegin("reopen-gates", "hooks/workflow-state/review-tests-reopen.js");
test("on a stale review scope the mark gate reopens review_tests; the reset and recorded-verdict gates do not", () => {
  const { reopenReviewTestsAfterWriteCode } = require(path.join(ROOT, "hooks", "workflow-state", "review-tests-reopen.js"));
  const { sid, repo } = staleReviewSession("reopen");
  assert.deepStrictEqual(reopenReviewTestsAfterWriteCode(sid, repo, "reset"), {});
  assert.deepStrictEqual(reopenReviewTestsAfterWriteCode(sid, repo, "recorded-verdict"), {});
  assert.strictEqual(recorded(sid, "review_tests").status, "complete", "reset / recorded-verdict left review_tests complete");
  // Control: the same fixture is reopenable, so the two {} above are the gate's verdict, not the fixture's.
  assert.deepStrictEqual(reopenReviewTestsAfterWriteCode(sid, repo, "mark"), { kind: "review-tests-reopened", detail: "write-code-stale" });
  assert.strictEqual(recorded(sid, "review_tests").status, "pending", "the mark gate reopened review_tests");
});

test("a recorded-verdict skip never completes write_code nor reopens review_tests", () => {
  const { recordStepVerdict, RECORDED_VERDICT_REASONS } = require(path.join(ROOT, "hooks", "workflow-state", "record-step-verdict.js"));
  const { sid, repo } = staleReviewSession("reopen-rv");
  X.F.S.markStep(sid, "outline", "pending");
  const res = recordStepVerdict(sid, "outline", "skipped", { gate: "recorded-verdict", skipReason: RECORDED_VERDICT_REASONS.outline, repoDir: repo });
  assert.strictEqual(res.ok, true, `the recorded-verdict write ran: ${JSON.stringify(res)}`);
  assert.strictEqual(recorded(sid, "outline").status, "skipped", "the recorded-verdict path wrote its skip");
  assert.notStrictEqual(recorded(sid, "write_code").status, "complete");
  assert.strictEqual(recorded(sid, "review_tests").status, "complete", "review_tests not reopened");
});

test("RESET_FROM_write_code leaves write_code pending (the reset gate never completes it)", () => {
  const sid = X.F.seedWf("reopen-wc", ["clarify_intent", "outline", "detail"]);
  X.mark(sid, R("write_code"));
  assert.notStrictEqual(recorded(sid, "write_code").status, "complete");
});
caseEnd();
