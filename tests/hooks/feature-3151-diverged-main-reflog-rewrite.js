"use strict";
// Tests: hooks/enforce-worktree/main-worktree-allows/standard.js
// Tags: enforce-worktree, main-worktree-cleanup, merge-recovery, reflog, feature-3151, scope:issue-specific, TL2, pwsh-not-required
// TL3 gap (what this test does NOT catch):
// - Whether the live Claude Code PreToolUse dispatch routes `git merge --no-edit origin/<b>` to
//   isAllowedMainWorktreeCleanup and turns its false into an ask in a real session.
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.
//
// #3151: the sanctioned divergence-recovery merge is allowed only when the last fetch of the remote-tracking ref was not a forced update (origin/<b>@{1} is an ancestor of origin/<b>); a rewritten or unreadable reflog falls back to ask.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const SB = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), "f3151-")));
const fwd = (p) => String(p).replace(/\\/g, "/");

// Pin git so neither the developer's global/system config nor an enclosing git hook env flips a verdict.
for (const n of ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_CEILING_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"]) delete process.env[n];
const EMPTY_GLOBAL = path.join(SB, "gitconfig-global");
fs.writeFileSync(EMPTY_GLOBAL, "");
Object.assign(process.env, {
  GIT_CONFIG_GLOBAL: fwd(EMPTY_GLOBAL), GIT_CONFIG_NOSYSTEM: "1", GIT_TERMINAL_PROMPT: "0",
  GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.com",
  GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.com",
});

const { isAllowedMainWorktreeCleanup } = require("../../hooks/enforce-worktree.js");

after(() => {
  restore();
  fs.rmSync(SB, { recursive: true, force: true });
});

function git(args, opts = {}) {
  const r = spawnSync("git", args, { encoding: "utf8", timeout: 20000, cwd: SB });
  if (!opts.allowFail && r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return r;
}

const REPO_CONFIG = [
  ["core.hooksPath", "/dev/null"], ["core.autocrlf", "false"], ["core.logAllRefUpdates", "true"],
  ["gc.auto", "0"], ["commit.gpgsign", "false"],
];
function configure(dir) {
  for (const [k, v] of REPO_CONFIG) git(["-C", dir, "config", k, v]);
}

function commitFile(dir, name, body, msg) {
  fs.writeFileSync(path.join(dir, name), body);
  git(["-C", dir, "add", name]);
  git(["-C", dir, "commit", "--no-verify", "-q", "-m", msg]);
}

// A bare remote, a seed clone that publishes to it, and a main clone with one local commit (ahead)
// whose upstream is origin/main. The main clone has no linked worktree (worktree count 1).
function scenario(name) {
  const root = path.join(SB, name);
  const remote = fwd(path.join(root, "remote.git"));
  const seed = fwd(path.join(root, "seed"));
  const main = fwd(path.join(root, "main"));
  fs.mkdirSync(root, { recursive: true });
  git(["init", "--bare", "-q", "-b", "main", remote]);
  git(["clone", "-q", remote, seed]);
  configure(seed);
  git(["-C", seed, "checkout", "-q", "-B", "main"]);
  commitFile(seed, "README.md", "init\n", "init");
  git(["-C", seed, "push", "-q", "origin", "main"]);
  git(["clone", "-q", remote, main]);
  configure(main);
  git(["-C", main, "branch", "-q", "--set-upstream-to=origin/main", "main"]);
  commitFile(main, "local.txt", "local\n", "local commit (ahead)");
  return { remote, seed, main };
}

// Fast-forward publish on the remote, then fetch: origin/main@{1} stays an ancestor.
function publishAndFetch(s, tag) {
  commitFile(s.seed, `${tag}.txt`, `${tag}\n`, `remote ${tag}`);
  git(["-C", s.seed, "push", "-q", "origin", "main"]);
  git(["-C", s.main, "fetch", "-q", "origin"]);
}

// History rewrite on the remote (force push), then fetch: origin/main@{1} is no longer an ancestor.
function rewriteAndFetch(s) {
  git(["-C", s.seed, "reset", "-q", "--hard", "HEAD~1"]);
  commitFile(s.seed, "rewritten.txt", "rewritten\n", "rewritten history");
  git(["-C", s.seed, "push", "-q", "--force", "origin", "main"]);
  git(["-C", s.main, "fetch", "-q", "origin"]);
}

const count = (dir, range) => Number(git(["-C", dir, "rev-list", "--count", range]).stdout.trim());
const isAncestorPrev = (dir) => git(["-C", dir, "merge-base", "--is-ancestor", "origin/main@{1}", "origin/main"], { allowFail: true }).status;
const prevResolves = (dir) => git(["-C", dir, "rev-parse", "--verify", "-q", "origin/main@{1}"], { allowFail: true }).status === 0;
function assertDiverged(dir) {
  assert.ok(count(dir, "origin/main..HEAD") >= 1, "fixture: main clone is ahead of origin/main");
  assert.ok(count(dir, "HEAD..origin/main") >= 1, "fixture: main clone is behind origin/main");
}
const MERGE = "git merge --no-edit origin/main";
const mergeC = (dir) => `git -C ${dir} merge --no-edit origin/main`;

// Built once: the fast-forward-diverged clone serves as the allow control for every reject case.
const FF = scenario("ff");
publishAndFetch(FF, "r1");
const FORCED = scenario("forced");
publishAndFetch(FORCED, "r1");
rewriteAndFetch(FORCED);

caseBegin("fast-forward-fetch-divergence-allows-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("fast-forward-fetch-divergence-allows-merge", () => {
  assertDiverged(FF.main);
  assert.equal(isAncestorPrev(FF.main), 0, "fixture: origin/main@{1} is an ancestor of origin/main");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, FF.main), true, "plain form");
  assert.equal(isAllowedMainWorktreeCleanup(mergeC(FF.main), FF.main), true, "-C <repoRoot> form");
});
caseEnd();

caseBegin("forced-update-fetch-rejects-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("forced-update-fetch-rejects-merge", () => {
  assertDiverged(FORCED.main);
  assert.equal(isAncestorPrev(FORCED.main), 1, "fixture: origin/main@{1} is not an ancestor (remote history rewritten)");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, FORCED.main), false, "plain form");
  assert.equal(isAllowedMainWorktreeCleanup(mergeC(FORCED.main), FORCED.main), false, "-C <repoRoot> form");
});
caseEnd();

caseBegin("forced-update-reject-leaves-repo-untouched", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("forced-update-reject-leaves-repo-untouched", () => {
  const head = git(["-C", FORCED.main, "rev-parse", "HEAD"]).stdout.trim();
  const tracking = git(["-C", FORCED.main, "rev-parse", "origin/main"]).stdout.trim();
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, FORCED.main), false);
  assert.equal(git(["-C", FORCED.main, "rev-parse", "HEAD"]).stdout.trim(), head, "HEAD unchanged by the classifier");
  assert.equal(git(["-C", FORCED.main, "rev-parse", "origin/main"]).stdout.trim(), tracking, "origin/main unchanged");
  assert.equal(isAncestorPrev(FORCED.main), 1, "the classifier does not repair the reflog evidence");
});
caseEnd();

caseBegin("missing-reflog-rejects-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("missing-reflog-rejects-merge", () => {
  const s = scenario("noreflog");
  publishAndFetch(s, "r1");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, s.main), true, "control: allowed while the reflog is intact");
  fs.rmSync(path.join(s.main, ".git", "logs", "refs", "remotes", "origin", "main"), { force: true });
  assertDiverged(s.main);
  assert.equal(prevResolves(s.main), false, "fixture: origin/main@{1} cannot be resolved");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, s.main), false);
});
caseEnd();

caseBegin("expired-reflog-rejects-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("expired-reflog-rejects-merge", () => {
  const s = scenario("expired");
  publishAndFetch(s, "r1");
  git(["-C", s.main, "reflog", "expire", "--expire=now", "--expire-unreachable=now", "refs/remotes/origin/main"]);
  assertDiverged(s.main);
  assert.equal(prevResolves(s.main), false, "fixture: reflog expired, origin/main@{1} cannot be resolved");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, s.main), false);
});
caseEnd();

caseBegin("fresh-clone-single-reflog-entry-rejects-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("fresh-clone-single-reflog-entry-rejects-merge", () => {
  const s = scenario("fresh");
  assert.equal(prevResolves(s.main), false, "fixture: a fresh clone has no origin/main@{1}");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, s.main), false);
});
caseEnd();

caseBegin("existing-merge-shape-rejects-kept", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("existing-merge-shape-rejects-kept", () => {
  git(["-C", FF.main, "branch", "-q", "feature", "HEAD"]);
  git(["-C", FF.main, "update-ref", "refs/remotes/origin/feature", "origin/main"]);
  for (const cmd of [
    "git merge --no-edit origin/feature", "git merge --ff-only origin/main", "git merge --ff-only --no-edit origin/main",
    "git merge --no-edit origin/main -m msg", "git merge origin/main", "git merge --no-edit",
  ]) assert.equal(isAllowedMainWorktreeCleanup(cmd, FF.main), false, cmd);
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, FF.main), true, "control: the sanctioned form on the same fixture");
});
caseEnd();

caseBegin("upstream-mismatch-rejects-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("upstream-mismatch-rejects-merge", () => {
  const s = scenario("noup");
  publishAndFetch(s, "r1");
  git(["-C", s.main, "branch", "-q", "--unset-upstream", "main"]);
  assert.equal(isAncestorPrev(s.main), 0, "fixture: the reflog alone would allow");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, s.main), false, "no upstream: C1 still rejects");
});
caseEnd();

caseBegin("cleanup-class-allows-kept", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("cleanup-class-allows-kept", () => {
  const wt = git(["-C", FORCED.main, "worktree", "list", "--porcelain"]).stdout.match(/^worktree\s/gm) || [];
  assert.equal(wt.length, 1, "fixture: no linked worktree, so the count gate allows cleanup");
  for (const cmd of ["git stash push", "git restore local.txt", "git checkout -- local.txt"]) {
    assert.equal(isAllowedMainWorktreeCleanup(cmd, FORCED.main), true, `${cmd} on a force-fetched clone`);
  }
  assert.equal(isAllowedMainWorktreeCleanup("git stash list --all", FORCED.main), false, "non-cleanup stash form");
});
caseEnd();

caseBegin("adversarial-operands-reject", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("adversarial-operands-reject", () => {
  for (const cmd of [
    "git merge --no-edit origin/main;touch pwned", "git merge --no-edit origin/main && git push",
    "git merge --no-edit origin/main | cat", "git merge --no-edit origin/$(id)", "git merge --no-edit origin/`id`",
    "git merge --no-edit refs/remotes/origin/main", "git merge --no-edit +origin/main",
    "git merge --no-edit origin/main:other", "git merge --no-edit origin/main@{1}",
    "git merge --no-edit origin/../main", "git -c core.editor=evil merge --no-edit origin/main",
    "GIT_EDITOR=evil git merge --no-edit origin/main", "git -C /tmp/elsewhere merge --no-edit origin/main",
  ]) assert.equal(isAllowedMainWorktreeCleanup(cmd, FF.main), false, cmd);
  assert.equal(fs.existsSync(path.join(SB, "pwned")), false, "no injected command ran");
  assert.equal(fs.existsSync(path.join(FF.main, "pwned")), false, "no injected command ran in the repo");
});
caseEnd();

caseBegin("two-fast-forward-fetches-allows-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("two-fast-forward-fetches-allows-merge", () => {
  const s = scenario("ff2");
  publishAndFetch(s, "r1");
  publishAndFetch(s, "r2");
  assertDiverged(s.main);
  assert.equal(isAncestorPrev(s.main), 0, "fixture: origin/main@{1} is an ancestor of origin/main");
  const prevVsHead = git(["-C", s.main, "merge-base", "--is-ancestor", "origin/main@{1}", "HEAD"], { allowFail: true }).status;
  assert.equal(prevVsHead, 1, "fixture: origin/main@{1} is not an ancestor of HEAD");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, s.main), true, "plain form");
  assert.equal(isAllowedMainWorktreeCleanup(mergeC(s.main), s.main), true, "-C <repoRoot> form");
});
caseEnd();

caseBegin("forced-then-fast-forward-allows-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("forced-then-fast-forward-allows-merge", () => {
  const s = scenario("forcedff");
  publishAndFetch(s, "r1");
  rewriteAndFetch(s);
  publishAndFetch(s, "r2");
  assertDiverged(s.main);
  assert.equal(isAncestorPrev(s.main), 0, "fixture: the latest fetch was a fast-forward");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, s.main), true);
});
caseEnd();

caseBegin("slash-branch-fast-forward-allows-and-forced-rejects", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("slash-branch-fast-forward-allows-and-forced-rejects", () => {
  const B = "feature/x";
  const s = scenario("slash");
  git(["-C", s.seed, "checkout", "-q", "-b", B]);
  git(["-C", s.seed, "push", "-q", "origin", B]);
  git(["-C", s.main, "fetch", "-q", "origin"]);
  git(["-C", s.main, "checkout", "-q", "-b", B, `origin/${B}`]);
  git(["-C", s.main, "branch", "-q", `--set-upstream-to=origin/${B}`, B]);
  commitFile(s.main, "slash-local.txt", "local\n", "local commit on feature/x");
  commitFile(s.seed, "x1.txt", "x1\n", "remote x1");
  git(["-C", s.seed, "push", "-q", "origin", B]);
  git(["-C", s.main, "fetch", "-q", "origin"]);
  const cmd = `git merge --no-edit origin/${B}`;
  const prev = () => git(["-C", s.main, "merge-base", "--is-ancestor", `origin/${B}@{1}`, `origin/${B}`], { allowFail: true }).status;
  assert.ok(count(s.main, `origin/${B}..HEAD`) >= 1 && count(s.main, `HEAD..origin/${B}`) >= 1, "fixture: diverged on feature/x");
  assert.equal(prev(), 0, "fixture: fast-forward fetch of origin/feature/x");
  assert.equal(isAllowedMainWorktreeCleanup(cmd, s.main), true, "fast-forward fetch allows");
  git(["-C", s.seed, "reset", "-q", "--hard", "HEAD~1"]);
  commitFile(s.seed, "x-rewritten.txt", "rw\n", "rewritten feature/x");
  git(["-C", s.seed, "push", "-q", "--force", "origin", B]);
  git(["-C", s.main, "fetch", "-q", "origin"]);
  assert.ok(count(s.main, `HEAD..origin/${B}`) >= 1, "fixture: still behind after the forced fetch");
  assert.equal(prev(), 1, "fixture: forced update of origin/feature/x");
  assert.equal(isAllowedMainWorktreeCleanup(cmd, s.main), false, "forced fetch rejects");
});
caseEnd();

caseBegin("logallrefupdates-false-rejects-merge", "hooks/enforce-worktree/main-worktree-allows/standard.js");
test("logallrefupdates-false-rejects-merge", () => {
  const s = scenario("nologall");
  git(["-C", s.main, "config", "core.logAllRefUpdates", "false"]);
  const logFile = path.join(s.main, ".git", "logs", "refs", "remotes", "origin", "main");
  fs.rmSync(logFile, { force: true });
  publishAndFetch(s, "r1");
  assertDiverged(s.main);
  assert.equal(fs.existsSync(logFile), false, "fixture: fetch created no reflog for origin/main");
  assert.equal(prevResolves(s.main), false, "fixture: origin/main@{1} cannot be resolved");
  assert.equal(isAllowedMainWorktreeCleanup(MERGE, s.main), false);
});
caseEnd();
