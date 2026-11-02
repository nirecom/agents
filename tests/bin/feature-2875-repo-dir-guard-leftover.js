"use strict";
// Tests: bin/workflow/lib/next-step/repo-dir-guard.js
// Tags: feature-2875, repo-dir-guard, next-step, leftover, worktree, indeterminate, fail-open, scope:issue-specific, TL2, pwsh-not-required
// #2875: when WE-11 fails, the session's recorded cwd is a leftover directory whose gitlink names a
// pruned admin dir, so git fails there and the repo check reads INDETERMINATE: next-step aborted
// with repo-dir-mismatch. The guard now fails open only for a self-call on an unregistered leftover
// of the SAME repo that this session demonstrably owned; every other INDETERMINATE stays fail-fast.
// TL3 gap: a real CWD-locked directory on Windows; the fixture reproduces its on-disk result.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");

const restoreIsolation = isolate();
const SB = F.makeBase("f2875g-");
after(() => {
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

const GUARD = F.rel("bin/workflow/lib/next-step/repo-dir-guard.js");
const { assertRepoDirMatchesSession, compareRepoIdentity, VERDICTS } = require(GUARD);

const M = F.makeRepo(path.join(SB, "main"));
const L = F.makeLeftover(M, path.join(SB, "wts", "gone"), "feature/gone").leftover;
const M2 = F.makeRepo(path.join(SB, "other-main"));
const L2 = F.makeLeftover(M2, path.join(SB, "other-wts", "gone"), "feature/other").leftover;
const LR = F.makeLeftover(M, path.join(SB, "wts", "work"), "feature/reused",
  { reuseAt: path.join(SB, "reuse", "work") }).leftover;
const PLAIN = path.join(SB, "plain");
fs.mkdirSync(PLAIN);

const self = { isExplicitSessionOverride: false };

caseBegin("fixture-leftover-reads-indeterminate", "bin/workflow/lib/next-step/repo-dir-guard.js");
test("fixture-leftover-reads-indeterminate", () => {
  assert.strictEqual(compareRepoIdentity(L, M), VERDICTS.INDETERMINATE);
  assert.strictEqual(compareRepoIdentity(L2, M), VERDICTS.INDETERMINATE);
  assert.strictEqual(compareRepoIdentity(PLAIN, M), VERDICTS.INDETERMINATE);
});
caseEnd();

caseBegin("fail-open-on-owned-leftover-by-session-worktree", "bin/workflow/lib/next-step/repo-dir-guard.js");
test("fail-open-on-owned-leftover-by-session-worktree", () => {
  F.seedState("g-sw", L);
  F.io().recordSessionWorktree("g-sw", L);
  const r = assertRepoDirMatchesSession("g-sw", M, self);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.strictEqual(r.reason, "repo-context-worktree-leftover");
  assert.strictEqual(r.verdict, VERDICTS.INDETERMINATE);
  assert.strictEqual(r.verifiedEquivalent, false);
});
caseEnd();

caseBegin("fail-open-on-owned-leftover-by-worktree-entry", "bin/workflow/lib/next-step/repo-dir-guard.js");
test("fail-open-on-owned-leftover-by-worktree-entry", () => {
  F.seedState("g-entry", M);
  F.enterWorktree("g-entry", L);
  const r = assertRepoDirMatchesSession("g-entry", M, self);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.strictEqual(r.reason, "repo-context-worktree-leftover");
});
caseEnd();

caseBegin("fail-open-on-owned-leftover-with-reused-admin-dir", "bin/workflow/lib/next-step/repo-dir-guard.js");
test("fail-open-on-owned-leftover-with-reused-admin-dir", () => {
  assert.ok(fs.existsSync(F.gitlinkTarget(LR)), "fixture: another worktree reuses the leftover's admin dir");
  F.seedState("g-reused", LR);
  F.io().recordSessionWorktree("g-reused", LR);
  const r = assertRepoDirMatchesSession("g-reused", M, self);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
});
caseEnd();

caseBegin("fail-fast-on-ownership-evidence-for-another-path", "bin/workflow/lib/next-step/repo-dir-guard.js");
test("fail-fast-on-ownership-evidence-for-another-path", () => {
  F.seedState("g-mismatch", L);
  F.io().recordSessionWorktree("g-mismatch", LR);
  const r = assertRepoDirMatchesSession("g-mismatch", M, self);
  assert.strictEqual(r.ok, false, JSON.stringify(r));
});
caseEnd();

caseBegin("fail-fast-without-ownership-evidence","bin/workflow/lib/next-step/repo-dir-guard.js");
test("fail-fast-without-ownership-evidence", () => {
  F.seedState("g-noevidence", L);
  const r = assertRepoDirMatchesSession("g-noevidence", M, self);
  assert.strictEqual(r.ok, false, JSON.stringify(r));
});
caseEnd();

caseBegin("fail-fast-on-explicit-session-override", "bin/workflow/lib/next-step/repo-dir-guard.js");
test("fail-fast-on-explicit-session-override", () => {
  F.seedState("g-override", L);
  F.io().recordSessionWorktree("g-override", L);
  const r = assertRepoDirMatchesSession("g-override", M, { isExplicitSessionOverride: true });
  assert.strictEqual(r.ok, false, JSON.stringify(r));
});
caseEnd();

caseBegin("fail-fast-on-leftover-of-another-repo", "bin/workflow/lib/next-step/repo-dir-guard.js");
test("fail-fast-on-leftover-of-another-repo", () => {
  F.seedState("g-otherrepo", L2);
  F.io().recordSessionWorktree("g-otherrepo", L2);
  const r = assertRepoDirMatchesSession("g-otherrepo", M, self);
  assert.strictEqual(r.ok, false, JSON.stringify(r));
});
caseEnd();

caseBegin("fail-fast-on-unknown-directory", "bin/workflow/lib/next-step/repo-dir-guard.js");
test("fail-fast-on-unknown-directory", () => {
  F.seedState("g-plain", PLAIN);
  F.io().recordSessionWorktree("g-plain", PLAIN);
  const r = assertRepoDirMatchesSession("g-plain", M, self);
  assert.strictEqual(r.ok, false, JSON.stringify(r));
});
caseEnd();
