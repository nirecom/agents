#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-gate/run-tests-approval-checker.js, hooks/workflow-gate/commit-gate-steps.js, hooks/lib/run-tests-completion-note.js
// Tags: TL2, hooks, workflow-gate, commit-gate, run-tests, baseline, approval, scope:issue-specific
// #3067 step 4: a baseline-unobserved approval is bound to the HEAD it was given at. The commit gate
// (collectIncompleteSteps, driven in-process) lets the commit made on that HEAD through, refuses any
// later non-docs-only commit, fails closed on a bad head or repo, and leaves other bases alone.
// TL3 gap (what this test does NOT catch):
// - workflow-gate.js computing docsOnly and repoDir from a live `git commit` tool call.
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

// Fixture isolation: pin the state / plans dirs to temp and unset the session ID before any hook loads.
const restore = isolate();
const F = require("../lib/baseline-unobserved-fixture");
after(() => { restore(); F.cleanup(); });

const mod = (rel) => require(path.join(F.ROOT, rel));
const checker = () => mod("hooks/workflow-gate/run-tests-approval-checker.js");
const short = (sha) => sha.slice(0, 7);

function skippableOf(id) {
  const ws = mod("hooks/workflow-state");
  const fn = ws.getSkippableSteps || mod("hooks/workflow-state/state-io").getSkippableSteps;
  return fn(id);
}

// scan(id, repo, docsOnly) — the commit gate's step scan exactly as workflow-gate.js calls it.
function scan(id, repo, docsOnly = false) {
  const { collectIncompleteSteps } = mod("hooks/workflow-gate/commit-gate-steps.js");
  return collectIncompleteSteps({ state: F.readState(id), commitSnapshot: null, sessionId: id, repoDir: repo,
    docsOnly, isWip: false, skippable: skippableOf(id) });
}
const runTestsBlocked = (r) => r.incomplete.includes("run_tests");
const reasonOf = (r) => String(r.incompleteReasons.run_tests || "");

// approved(label, o) — a fixture repo plus a session approved at its current HEAD (H0).
function approved(label, o = {}) {
  const repo = F.repo(label);
  const h0 = F.headOf(repo);
  const id = F.sid(label);
  F.seedApproved(id, Object.assign({ head: h0 }, o));
  return { repo, h0, id };
}

function assertReapprovalReason(reason, approvalHead, currentHead, label) {
  assert.ok(reason.includes(short(approvalHead)), `${label}: names the approval head ${short(approvalHead)}: ${reason}`);
  assert.ok(reason.includes(short(currentHead)), `${label}: names the current HEAD ${short(currentHead)}: ${reason}`);
  for (const step of ["/run-tests", "bin/run-tests-baseline", F.SENTINEL_NAME]) {
    assert.ok(reason.includes(step), `${label}: names the re-approval step ${step}: ${reason}`);
  }
}

caseBegin("head-moved-after-approval-blocks", "hooks/workflow-gate/commit-gate-steps.js");
test("head-moved-after-approval-blocks", () => {
  const { repo, h0, id } = approved("moved");
  const h1 = F.commit(repo, "src2.txt");
  F.stage(repo, "src.txt");
  const r = scan(id, repo);
  assert.ok(runTestsBlocked(r), `run_tests is incomplete: ${JSON.stringify(r.incompleteReasons)}`);
  assertReapprovalReason(reasonOf(r), h0, h1, "moved");
  assert.equal(F.runTests(id).status, "complete", "the gate only refuses; state is not rewritten");
});
caseEnd();

caseBegin("approval-commit-passes-and-stays-disclosed", "hooks/lib/run-tests-completion-note.js");
test("approval-commit-passes-and-stays-disclosed", () => {
  const { repo, id } = approved("normal");
  F.stage(repo, "src.txt");
  const r = scan(id, repo);
  assert.ok(!runTestsBlocked(r), `the commit on the approval HEAD passes: ${reasonOf(r)}`);
  F.git(repo, ["commit", "-q", "-m", "the approved commit"]);
  const { readCompletionNote } = mod("hooks/lib/run-tests-completion-note.js");
  const note = String(readCompletionNote(id));
  assert.match(note, /^- Unverified tests: 1 failing test\(s\) accepted by the user without a base observation \(details: unrunnable-at-base;/,
    "the Final Report / PR body line survives the HEAD move");
});
caseEnd();

caseBegin("second-commit-after-use-blocks-unless-docs-only", "hooks/workflow-gate/commit-gate-steps.js");
test("second-commit-after-use-blocks-unless-docs-only", () => {
  const { repo, h0, id } = approved("second");
  F.stage(repo, "src.txt");
  assert.ok(!runTestsBlocked(scan(id, repo)), "control: the first commit passes");
  F.git(repo, ["commit", "-q", "-m", "the approved commit"]);
  const h1 = F.headOf(repo);
  F.stage(repo, "lib/code.js");
  const again = scan(id, repo);
  assert.ok(runTestsBlocked(again), `a second non-docs-only commit is refused: ${JSON.stringify(again.incompleteReasons)}`);
  assertReapprovalReason(reasonOf(again), h0, h1, "second");
  F.git(repo, ["reset", "-q"]);
  F.stage(repo, "docs/guide.md");
  const docs = scan(id, repo, true);
  assert.ok(!runTestsBlocked(docs), `a docs-only commit passes: ${reasonOf(docs)}`);
});
caseEnd();

caseBegin("checker-pass-on-matching-head-or-docs-only", "hooks/workflow-gate/run-tests-approval-checker.js");
test("checker-pass-on-matching-head-or-docs-only", () => {
  const { checkUnobservedApproval } = checker();
  const { repo, id } = approved("checker-pass");
  assert.equal(checkUnobservedApproval(F.runTests(id), { repoDir: repo, docsOnly: false }).action, "pass", "matching head");
  F.commit(repo, "src2.txt");
  const moved = checkUnobservedApproval(F.runTests(id), { repoDir: repo, docsOnly: false });
  assert.equal(moved.action, "block", "control: the moved head blocks");
  assert.equal(checkUnobservedApproval(F.runTests(id), { repoDir: repo, docsOnly: true }).action, "pass", "docs-only");
});
caseEnd();

// [name, accept record (head bound later), repoDir: "repo" | "not-git"]
const FAIL_CLOSED = [
  ["head-missing", (h) => ({ reason: "r-r-r", tests: [] }), "repo"],
  ["head-corrupt", (h) => ({ reason: "r-r-r", head: "zzz", tests: [] }), "repo"],
  ["head-uppercase", (h) => ({ reason: "r-r-r", head: h.toUpperCase(), tests: [] }), "repo"],
  ["head-short", (h) => ({ reason: "r-r-r", head: short(h), tests: [] }), "repo"],
  ["accept-missing", () => null, "repo"],
  ["repo-not-git", (h) => ({ reason: "r-r-r", head: h, tests: [] }), "not-git"],
];

caseBegin("checker-fails-closed", "hooks/workflow-gate/run-tests-approval-checker.js");
test("checker-fails-closed", () => {
  const { checkUnobservedApproval } = checker();
  for (const [name, acceptOf, where] of FAIL_CLOSED) {
    const repo = F.repo(name);
    const h0 = F.headOf(repo);
    const id = F.sid(name);
    F.seedApproved(id, { head: h0, accept: acceptOf(h0) });
    const dir = where === "repo" ? repo : fs.mkdtempSync(path.join(F.TMP, "not-git-"));
    const v = checkUnobservedApproval(F.runTests(id), { repoDir: dir, docsOnly: false });
    assert.equal(v.action, "block", `${name}: blocked`);
    assert.ok(typeof v.reason === "string" && v.reason !== "", `${name}: carries a reason`);
  }
});
caseEnd();

caseBegin("gate-fails-closed-on-missing-head", "hooks/workflow-gate/commit-gate-steps.js");
test("gate-fails-closed-on-missing-head", () => {
  const { repo, id } = approved("gate-no-head", { accept: { reason: "r-r-r", tests: [] } });
  F.stage(repo, "src.txt");
  const r = scan(id, repo);
  assert.ok(runTestsBlocked(r), `run_tests is incomplete: ${JSON.stringify(r.incompleteReasons)}`);
  assert.notEqual(reasonOf(r), "", "incompleteReasons.run_tests is set");
});
caseEnd();

const OTHER_BASES = ["unrunnable-accepted", "baseline-auto-accepted", null];

caseBegin("other-bases-are-not-judged", "hooks/workflow-gate/run-tests-approval-checker.js");
test("other-bases-are-not-judged", () => {
  const { checkUnobservedApproval } = checker();
  for (const basis of OTHER_BASES) {
    const label = `other-${basis}`;
    const { repo, id } = approved(label, { basis });
    F.commit(repo, "src2.txt");
    F.stage(repo, "src.txt");
    const v = checkUnobservedApproval(F.runTests(id), { repoDir: repo, docsOnly: false });
    assert.equal(v.action, "pass", `${label}: the checker does not judge this basis`);
    const r = scan(id, repo);
    assert.ok(!runTestsBlocked(r), `${label}: run_tests stays settled: ${reasonOf(r)}`);
  }
});
caseEnd();
