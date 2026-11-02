"use strict";
// Tests: hooks/workflow-state/resolve-worktree-path.js, bin/lib/resume-session/upstream-cwd.js, hooks/workflow-state/inheritance/granularity.js, hooks/workflow-mark/branching-handler.js, hooks/workflow-state/review-tests-reopen.js
// Tags: feature-2875, worktree, ownership, leftover, gitlink, resolve-worktree-path, scope:issue-specific, TL2, pwsh-not-required
// #2875 root cause 2: a directory WE-11 failed to remove keeps a `.git` gitlink, so "exists and is
// not main" called it a live worktree. The fs-only ownership predicate (gitlink -> admin dir ->
// back-reference) and the leftover classifier replace that test at the resolver and its siblings.
// Real `git worktree add` / `prune` fixtures; state and plans dirs pinned by isolate().
// TL3 gap: only a real Windows CWD lock reproduces the WE-11 failure the fixture simulates by prune.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");

const restoreIsolation = isolate();
const SB = F.makeBase("f2875o-");
after(() => {
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

const RWP = "hooks/workflow-state/resolve-worktree-path.js";
const isOwned = () => F.need(RWP, "isOwnedLinkedWorktree");
const classify = () => F.need(RWP, "classifyWorktreeLeftover");
const p = (...xs) => path.join(SB, ...xs);

// One main repo M with a live worktree W, a pruned leftover L (admin dir gone), and a leftover R
// whose admin dir a later worktree R2 of the same basename reused.
const M = F.makeRepo(p("main"));
const W = F.addWorktree(M, p("wts", "live"), "feature/live");
const L = F.makeLeftover(M, p("wts", "gone"), "feature/gone").leftover;
fs.mkdirSync(p("wts2"));
const R = F.makeLeftover(M, p("wts", "reused"), "feature/reused", { reuseAt: p("wts2", "reused") }).leftover;
const PLAIN = p("plain");
fs.mkdirSync(PLAIN);
const COMMON = path.join(M, ".git");

caseBegin("predicate-true-for-live-linked-worktree", "hooks/workflow-state/resolve-worktree-path.js");
test("predicate-true-for-live-linked-worktree", () => {
  assert.strictEqual(isOwned()(W), true);
});
caseEnd();

caseBegin("predicate-accepts-relative-gitdir", "hooks/workflow-state/resolve-worktree-path.js");
test("predicate-accepts-relative-gitdir", () => {
  const wt = F.addWorktree(M, p("wts", "relgit"), "feature/relgit");
  const admin = F.gitlinkTarget(wt);
  // Git for Windows marks the gitlink hidden, and a hidden file cannot be truncated in place.
  fs.unlinkSync(path.join(wt, ".git"));
  fs.writeFileSync(path.join(wt, ".git"), `gitdir: ${path.relative(wt, admin).replace(/\\/g, "/")}\n`);
  assert.strictEqual(isOwned()(wt), true, "a relative gitdir resolves against the worktree dir");
});
caseEnd();

caseBegin("predicate-false-for-main-worktree", "hooks/workflow-state/resolve-worktree-path.js");
test("predicate-false-for-main-worktree", () => {
  assert.strictEqual(isOwned()(M), false);
});
caseEnd();

caseBegin("predicate-false-for-reused-admin-gitlink", "hooks/workflow-state/resolve-worktree-path.js");
test("predicate-false-for-reused-admin-gitlink", () => {
  assert.ok(fs.existsSync(F.gitlinkTarget(R)), "fixture: the admin dir must have been reused");
  assert.strictEqual(isOwned()(R), false);
});
caseEnd();

caseBegin("predicate-false-for-missing-admin-gitlink", "hooks/workflow-state/resolve-worktree-path.js");
test("predicate-false-for-missing-admin-gitlink", () => {
  assert.ok(!fs.existsSync(F.gitlinkTarget(L)), "fixture: prune must have removed the admin dir");
  assert.strictEqual(isOwned()(L), false);
});
caseEnd();

caseBegin("predicate-false-when-back-reference-differs", "hooks/workflow-state/resolve-worktree-path.js");
test("predicate-false-when-back-reference-differs", () => {
  const wt = F.addWorktree(M, p("wts", "backref"), "feature/backref");
  fs.writeFileSync(path.join(F.gitlinkTarget(wt), "gitdir"), `${p("elsewhere", ".git").replace(/\\/g, "/")}\n`);
  assert.strictEqual(isOwned()(wt), false);
  assert.strictEqual(classify()(wt).kind, "unregistered-leftover");
});
caseEnd();

caseBegin("classify-returns-four-kinds-with-common-dir", "hooks/workflow-state/resolve-worktree-path.js");
test("classify-returns-four-kinds-with-common-dir", () => {
  const c = classify();
  const owned = c(W);
  assert.strictEqual(owned.kind, "owned");
  assert.ok(F.samePath(owned.commonDir, COMMON), `owned commonDir: ${owned.commonDir}`);
  assert.strictEqual(c(M).kind, "foreign");
  for (const dir of [L, R]) {
    const left = c(dir);
    assert.strictEqual(left.kind, "unregistered-leftover", dir);
    assert.ok(F.samePath(left.commonDir, COMMON), `leftover commonDir: ${left.commonDir}`);
  }
  const none = c(PLAIN);
  assert.strictEqual(none.kind, "unknown");
  assert.strictEqual(none.commonDir, null);
  F.writeGitlink(p("garbage"), "");
  fs.writeFileSync(p("garbage", ".git"), "not a gitlink\n");
  assert.strictEqual(c(p("garbage")).kind, "unknown");
  F.writeGitlink(p("nocommon"), p("absent-repo", ".git", "worktrees", "x").replace(/\\/g, "/"));
  const nc = c(p("nocommon"));
  assert.strictEqual(nc.kind, "unknown");
  assert.strictEqual(nc.commonDir, null);
});
caseEnd();

caseBegin("classify-treats-enoent-worktrees-dir-as-empty", "hooks/workflow-state/resolve-worktree-path.js");
test("classify-treats-enoent-worktrees-dir-as-empty", () => {
  const solo = F.makeRepo(p("solo"));
  const left = F.makeLeftover(solo, p("solo-wts", "only"), "feature/only").leftover;
  assert.ok(!fs.existsSync(path.join(solo, ".git", "worktrees")), "fixture: prune must remove the empty worktrees dir");
  const r = classify()(left);
  assert.strictEqual(r.kind, "unregistered-leftover");
  assert.ok(F.samePath(r.commonDir, path.join(solo, ".git")), `commonDir: ${r.commonDir}`);
});
caseEnd();

caseBegin("classify-unknown-when-worktrees-dir-unreadable", "hooks/workflow-state/resolve-worktree-path.js");
test("classify-unknown-when-worktrees-dir-unreadable", () => {
  const odd = F.makeRepo(p("odd"));
  fs.writeFileSync(path.join(odd, ".git", "worktrees"), "a file where a directory belongs\n");
  F.writeGitlink(p("odd-left"), path.join(odd, ".git", "worktrees", "x").replace(/\\/g, "/"));
  assert.strictEqual(classify()(p("odd-left")).kind, "unknown");
});
caseEnd();

caseBegin("predicate-and-classify-spawn-no-git", "hooks/workflow-state/resolve-worktree-path.js");
test("predicate-and-classify-spawn-no-git", () => {
  const dirs = [W, M, L, R, PLAIN];
  const expected = dirs.map((d) => ({ owned: isOwned()(d), kind: classify()(d).kind }));
  const child = [
    "const cp = require('child_process'); let spawned = 0;",
    "for (const k of ['spawn','spawnSync','exec','execSync','execFile','execFileSync','fork']) {",
    "  cp[k] = function () { spawned++; throw new Error('spawn attempted'); };",
    "}",
    "const m = require(process.argv[1]);",
    "const out = process.argv.slice(2).map((d) => ({ owned: m.isOwnedLinkedWorktree(d), kind: m.classifyWorktreeLeftover(d).kind }));",
    "process.stdout.write(JSON.stringify({ spawned, out }));",
  ].join("\n");
  const env = Object.assign({}, process.env, { PATH: "", Path: "" });
  const r = F.runNode(["-e", child, F.rel(RWP), ...dirs], { env });
  assert.strictEqual(r.rc, 0, r.err);
  const got = JSON.parse(r.out);
  assert.strictEqual(got.spawned, 0, "the predicate and the classifier must not spawn");
  assert.deepStrictEqual(got.out, expected);
});
caseEnd();

caseBegin("resolver-skips-leftover-candidates", "hooks/workflow-state/resolve-worktree-path.js");
test("resolver-skips-leftover-candidates", () => {
  const { resolveSessionWorktreePath } = require(F.rel(RWP));
  F.seedState("rslv-only-leftover", R);
  assert.strictEqual(resolveSessionWorktreePath("rslv-only-leftover"), null);
  F.seedState("rslv-falls-through", R);
  F.io().recordSessionWorktree("rslv-falls-through", W);
  assert.ok(F.samePath(resolveSessionWorktreePath("rslv-falls-through"), W));
});
caseEnd();

caseBegin("upstream-cwd-does-not-call-leftover-live", "bin/lib/resume-session/upstream-cwd.js");
test("upstream-cwd-does-not-call-leftover-live", () => {
  const { classifyUpstreamCwd, CWD_CLASSES } = require(F.rel("bin/lib/resume-session/upstream-cwd.js"));
  F.seedState("up-leftover", R);
  const r = classifyUpstreamCwd("up-leftover");
  assert.strictEqual(r.classification, CWD_CLASSES.WORKTREE_GONE);
  assert.strictEqual(r.worktree_path, null);
  F.seedState("up-live", W);
  assert.strictEqual(classifyUpstreamCwd("up-live").classification, CWD_CLASSES.LIVE_LINKED_WORKTREE);
});
caseEnd();

// The common WE-11 shape: prune removed the admin dir, so git fails inside the leftover and
// isMainWorktree's fail-open answer would call it main unless the leftover is skipped first.
caseBegin("upstream-cwd-pruned-leftover-is-gone-not-main", "bin/lib/resume-session/upstream-cwd.js");
test("upstream-cwd-pruned-leftover-is-gone-not-main", () => {
  const { classifyUpstreamCwd, CWD_CLASSES } = require(F.rel("bin/lib/resume-session/upstream-cwd.js"));
  assert.ok(!fs.existsSync(F.gitlinkTarget(L)), "fixture: prune must have removed the admin dir");
  F.seedState("up-pruned", L);
  const r = classifyUpstreamCwd("up-pruned");
  assert.strictEqual(r.classification, CWD_CLASSES.WORKTREE_GONE);
  assert.notStrictEqual(r.classification, CWD_CLASSES.MAIN_CHECKOUT);
  assert.strictEqual(r.worktree_path, null);
});
caseEnd();

caseBegin("granularity-upstream-cwd-skips-leftover", "hooks/workflow-state/inheritance/granularity.js");
test("granularity-upstream-cwd-skips-leftover", () => {
  const { upstreamCwdOf } = require(F.rel("hooks/workflow-state/inheritance/granularity.js"));
  const state = { cwd: R, session_worktree: W, session_start_context: { cwd: M } };
  assert.ok(F.samePath(upstreamCwdOf(state), W), "a leftover cwd must not win over the live session_worktree");
});
caseEnd();

// The session's state points at main and records W, so the resolver answers W: a leftover handed
// in as repoDir must fall through to it, while a live linked worktree is used as given.
caseBegin("review-tests-reopen-skips-leftover-repo-dir", "hooks/workflow-state/review-tests-reopen.js");
test("review-tests-reopen-skips-leftover-repo-dir", () => {
  const { resolveReopenRepoDir } = require(F.rel("hooks/workflow-state/review-tests-reopen.js"));
  F.seedState("reopen-sid", M);
  F.io().recordSessionWorktree("reopen-sid", W);
  for (const dir of [R, L]) {
    const got = resolveReopenRepoDir("reopen-sid", dir);
    assert.ok(F.samePath(got, W), `a leftover repoDir must resolve to the session worktree, got ${got} for ${dir}`);
  }
  const live = F.addWorktree(M, p("wts", "reopen-live"), "feature/reopen-live");
  assert.ok(F.samePath(resolveReopenRepoDir("reopen-sid", live), live), "a live linked worktree is used as given");
});
caseEnd();

// branching-handler runs in a child with its collaborators stubbed through require.cache, so only
// the session_worktree decision is exercised; recordSessionWorktree's argument is the observable.
function branchingRecords(wtPath) {
  const child = [
    "const path = require('path'); const root = process.argv[1]; const recorded = [];",
    "const stub = (r, exp) => { const f = require.resolve(path.join(root, r)); require.cache[f] = { id: f, filename: f, loaded: true, exports: exp }; };",
    "stub('hooks/workflow-state.js', { markStep() {}, readState() { return null; }, setDeliveryProfile() {},",
    "  recordSessionWorktree(sid, p) { recorded.push(p); }, recordMergeBaseBaseline() { return { recorded: false, reason: 'write-once' }; } });",
    "stub('hooks/workflow-state/plan-approval-check.js', { checkPlanApproval() { return { verdict: 'approved' }; } });",
    "stub('hooks/workflow-state/completion-approval.js', { recoveryFor() { return ''; } });",
    "stub('hooks/workflow-mark/branching-reconcile.js', { reconcileDeliveryPath() { return { ok: true, deliveryPath: 'pull_request' }; } });",
    "stub('hooks/lib/auto-merge-config.js', { readAutoMergePr() { return { value: 'off', source: 'default' }; } });",
    "const { handle } = require(path.join(root, 'hooks/workflow-mark/branching-handler.js'));",
    "const msgs = [];",
    "handle({ cmd: process.argv[2], sessionId: 'bh-sid', repoCwd: process.cwd(), pushMessage: (m) => msgs.push(m), signalFatal: (m) => msgs.push(m) });",
    "process.stdout.write(JSON.stringify({ recorded, msgs }));",
  ].join("\n");
  const cmd = `echo "<<WORKFLOW_BRANCHING_COMPLETE: worktree: ${wtPath.replace(/\\/g, "/")}>>"`;
  const r = F.runNode(["-e", child, F.ROOT, cmd], { cwd: SB });
  assert.strictEqual(r.rc, 0, r.err);
  return JSON.parse(r.out).recorded;
}

caseBegin("branching-handler-records-null-for-leftover", "hooks/workflow-mark/branching-handler.js");
test("branching-handler-records-null-for-leftover", () => {
  const live = branchingRecords(W);
  assert.strictEqual(live.length, 1, "fixture: the handler must reach recordSessionWorktree");
  assert.ok(F.samePath(live[0], W), `live worktree recorded as ${live[0]}`);
  assert.deepStrictEqual(branchingRecords(R), [null]);
});
caseEnd();
