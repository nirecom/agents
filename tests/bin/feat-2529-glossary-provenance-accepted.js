#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-provenance.js, bin/check-glossary-provenance, bin/review-doc-glossary, bin/review-doc-gates, hooks/workflow-gate/review-docs-checker.js, hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/glossary-accept-handler.js
// Tags: TL2, bin, hooks, glossary, provenance, commit-gate, sentinel, approval, scope:issue-specific, decision-time-limit
// #2529 S1 — glossary provenance, accepted part (T3-6). Split from
// feat-2529-glossary-provenance.js for the per-file time budget; same fixture library.

// TL3 gap: Claude Code itself does not deliver the PostToolUse call; the tests feed the real
// workflow-mark hook its input JSON, and the commit gate is driven through checkReviewDocs.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { totals } = require("./feat-2529-glossary-provenance/common");
const acc = require("./feat-2529-glossary-provenance/accepted");

const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));

caseBegin("t3-6-block-record-and-grant", "hooks/workflow-mark/glossary-accept-handler.js");
test("t3-6-block-record-and-grant", () => noNewFailures(fails, acc.blockRecordAndGrant));
caseEnd();

caseBegin("t3-6-narrow-grants-on-a-move", "hooks/workflow-mark/glossary-accept-handler.js");
test("t3-6-narrow-grants-on-a-move", () => noNewFailures(fails, acc.narrowGrants));
caseEnd();

caseBegin("t3-6-b-grants-follow-the-same-rules", "bin/check-glossary-provenance");
test("t3-6-b-grants-follow-the-same-rules", () => noNewFailures(fails, acc.bGrantSameRules));
caseEnd();

caseBegin("provenance-grant-carried-while-the-blocked-set-is-unchanged", "bin/check-glossary-provenance");
test("provenance-grant-carried-while-the-blocked-set-is-unchanged", () => noNewFailures(fails, acc.carryOnUnchangedBlocked));
caseEnd();

caseBegin("provenance-lapsed-grant-shown-on-the-block-line", "bin/check-glossary-provenance");
test("provenance-lapsed-grant-shown-on-the-block-line", () => noNewFailures(fails, acc.lapsedGrantShown));
caseEnd();

caseBegin("provenance-expired-grants-kept-per-norm-operation-category", "bin/check-glossary-provenance");
test("provenance-expired-grants-kept-per-norm-operation-category", () => noNewFailures(fails, acc.expiredKeptPerKey));
caseEnd();

// #2849 / #2781: checkReviewDocs under the decision time limit. bin/review-doc-gates is swapped
// for a stub (in process) or a hung node child (decision-limit-driver.js); git runs for real.
const assert = require("node:assert");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { gitInit } = require("../lib/harness");

const LIMIT_ENV = "WORKFLOW_DECISION_TIME_LIMIT_MS";
const GATES_TIMEOUT_REASON = "review-doc-gates did not finish within the decision time limit";
const GENERIC_REASON = "reached before bash ";
const FIX_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2849-review-docs-"));
after(() => fs.rmSync(FIX_ROOT, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }));
let fixSeq = 0;
// docRepo(stageMd) -> a fixture repo, with a.md staged when stageMd is true.
function docRepo(stageMd) {
  fixSeq += 1;
  const dir = path.join(FIX_ROOT, `repo-${fixSeq}`);
  fs.mkdirSync(dir);
  gitInit(dir);
  if (stageMd) {
    fs.writeFileSync(path.join(dir, "a.md"), "# A\n");
    const added = childProcess.spawnSync("git", ["-C", dir, "add", "a.md"], { encoding: "utf8", timeout: 30000 });
    assert.strictEqual(added.status, 0, `git add: ${added.stderr}`);
  }
  return dir;
}
// withGates(answer, fn): bin/review-doc-gates calls are answered by answer(args); the rest run.
function withGates(answer, fn) {
  const real = childProcess.spawnSync;
  const gateCalls = [];
  childProcess.spawnSync = (command, args, options) => {
    if (Array.isArray(args) && args.some((a) => String(a).includes("review-doc-gates"))) {
      gateCalls.push(args);
      return answer(args);
    }
    return real(command, args, options);
  };
  try { return { value: fn(), gateCalls }; } finally { childProcess.spawnSync = real; }
}
const checker = () => require("../../hooks/workflow-gate/review-docs-checker");
const gatesResult = (status, error) => ({ status, signal: null, stdout: "", stderr: "", error });

caseBegin("review-docs-checker-not-review-docs-step", "hooks/workflow-gate/review-docs-checker.js");
test("checkReviewDocs: any other step is not_handled and runs no gates", () => {
  const { value, gateCalls } = withGates(() => gatesResult(0), () => checker().checkReviewDocs("write_code", {}, { repoDir: docRepo(true) }));
  assert.deepStrictEqual(value, { action: "not_handled" });
  assert.strictEqual(gateCalls.length, 0);
});
caseEnd();

caseBegin("review-docs-checker-nothing-staged-skips", "hooks/workflow-gate/review-docs-checker.js");
test("checkReviewDocs: no staged .md -> skip without running the gates", () => {
  const { value, gateCalls } = withGates(() => gatesResult(1), () => checker().checkReviewDocs("review_docs", {}, { repoDir: docRepo(false) }));
  assert.deepStrictEqual(value, { action: "skip" });
  assert.strictEqual(gateCalls.length, 0);
});
caseEnd();

caseBegin("review-docs-checker-gates-verdicts", "hooks/workflow-gate/review-docs-checker.js");
test("checkReviewDocs: gates exit 0 -> skip, exit 2 -> doc-gates-failed, spawn error -> doc-gates-unavailable", () => {
  const repoDir = docRepo(true);
  const cases = [
    [gatesResult(0), { action: "skip" }],
    [gatesResult(2), { action: "block", reason: "doc-gates-failed" }],
    [gatesResult(null, Object.assign(new Error("spawn bash ENOENT"), { code: "ENOENT" })), { action: "block", reason: "doc-gates-unavailable" }],
  ];
  for (const [answer, want] of cases) {
    const { value, gateCalls } = withGates(() => answer, () => checker().checkReviewDocs("review_docs", {}, { repoDir }));
    assert.deepStrictEqual(value, want);
    assert.strictEqual(gateCalls.length, 1, "the gates run once");
    assert.ok(gateCalls[0].includes("--staged"), `gates args: ${gateCalls[0]}`);
  }
});
caseEnd();

caseBegin("review-docs-checker-hang-asks-at-short-limit", "hooks/workflow-gate/review-docs-checker.js");
test("TL2 checkReviewDocs armed with WORKFLOW_DECISION_TIME_LIMIT_MS=1500, gates hang: ask naming review-doc-gates at the limit", () => {
  const repoDir = docRepo(true);
  const env = { ...process.env, [LIMIT_ENV]: "1500" };
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  const startMs = Date.now();
  const done = childProcess.spawnSync(process.execPath, [path.join(__dirname, "feat-2529-glossary-provenance", "decision-limit-driver.js"), repoDir],
    { env, cwd: os.tmpdir(), encoding: "utf8", timeout: 60000 });
  const wallMs = Date.now() - startMs;
  assert.strictEqual(done.status, 0, `driver exit (stderr: ${done.stderr})`);
  const out = JSON.parse(String(done.stdout).trim().split("\n")[0]);
  assert.ok(out.hookSpecificOutput, `an ask, not a result: ${done.stdout}`);
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
  const reason = out.hookSpecificOutput.permissionDecisionReason;
  // Contract (#2849 review): the checker names its own gate, not the wrapper's generic bash message.
  assert.ok(reason.includes(GATES_TIMEOUT_REASON), `reason names the gates timeout: ${reason}`);
  assert.ok(!reason.includes(GENERIC_REASON), `not the generic wrapper form: ${reason}`);
  assert.ok(wallMs < 8000, `asked after ${wallMs} ms`);
});
caseEnd();
