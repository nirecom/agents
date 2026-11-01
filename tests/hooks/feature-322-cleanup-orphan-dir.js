"use strict";
// Tests: hooks/cleanup-orphan-dir.js
// Tags: feature-322, feature-2875, cleanup-orphan-dir, worktree, leftover, gitlink, expect-main-root, scan-cap, scope:issue-specific, TL2, pwsh-not-required
// #322 / #2875: a WE-11 leftover keeps its `.git` gitlink, so cleanup-orphan-dir refused it forever
// and a large leftover also hit the 5000-entry scan cap. With --expect-main-root, a gitlink whose
// ownership is proven (unregistered leftover of the caller's main repo) takes a capped-free path;
// everything without that proof keeps today's refusals. The CLI is spawned with WORKTREE_BASE_DIR
// pinned to the fixture base; its registered-worktree check still reads this checkout's real repo.
// TL3 gap: a real Windows CWD lock on the leftover, which only a live failed WE-11 produces.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");

const restoreIsolation = isolate();
const SB = F.makeBase("f322c-");
const BASE = path.join(SB, "wts");
fs.mkdirSync(BASE);
after(() => {
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

const CLI = F.rel("hooks/cleanup-orphan-dir.js");
const MAIN = F.makeRepo(path.join(SB, "repos", "main"));
let seq = 0;

function cleanup(args) {
  const env = Object.assign({}, process.env, { WORKTREE_BASE_DIR: BASE });
  return F.runNode([CLI, ...args], { cwd: SB, env, timeout: 110000 });
}

// A fresh leftover of MAIN under BASE (admin dir pruned), optionally padded with `files` files.
function leftover(files = 0) {
  const dir = F.makeLeftover(MAIN, path.join(BASE, `left-${++seq}`), `feature/left-${seq}`).leftover;
  fill(dir, files);
  return dir;
}

function fill(dir, files) {
  for (let d = 0; d * 500 < files; d++) {
    const sub = path.join(dir, "pad", `d${d}`);
    fs.mkdirSync(sub, { recursive: true });
    for (let i = d * 500; i < Math.min(files, (d + 1) * 500); i++) fs.writeFileSync(path.join(sub, `f${i}.txt`), "x");
  }
}

function assertDeleted(r, dir) {
  assert.strictEqual(r.rc, 0, `stderr: ${r.err}`);
  const out = JSON.parse(r.out.trim());
  assert.strictEqual(out.deleted, true);
  assert.ok(F.samePath(out.path, dir), `path: ${out.path}`);
  assert.ok(!fs.existsSync(dir), "the leftover must be gone");
}

function assertRefused(r, dir) {
  assert.strictEqual(r.rc, 1, `stdout: ${r.out} stderr: ${r.err}`);
  assert.ok(/^cleanup-orphan-dir: /m.test(r.err), r.err);
  assert.ok(fs.existsSync(dir), "a refused target must stay on disk");
}

caseBegin("gitlink-leftover-deleted-with-matching-main-root", "hooks/cleanup-orphan-dir.js");
test("gitlink-leftover-deleted-with-matching-main-root", () => {
  const dir = leftover(3);
  assertDeleted(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
});
caseEnd();

caseBegin("gitlink-leftover-deleted-when-worktrees-dir-absent", "hooks/cleanup-orphan-dir.js");
test("gitlink-leftover-deleted-when-worktrees-dir-absent", () => {
  const solo = F.makeRepo(path.join(SB, "repos", "solo"));
  const dir = F.makeLeftover(solo, path.join(BASE, "solo-only"), "feature/solo").leftover;
  assert.ok(!fs.existsSync(path.join(solo, ".git", "worktrees")), "fixture: prune removed the worktrees dir");
  assertDeleted(cleanup(["--force-if-not-registered", "--expect-main-root", solo, dir]), dir);
});
caseEnd();

caseBegin("large-gitlink-leftover-deleted-past-scan-cap", "hooks/cleanup-orphan-dir.js");
test("large-gitlink-leftover-deleted-past-scan-cap", () => {
  const dir = leftover(6000);
  assertDeleted(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
});
caseEnd();

caseBegin("gitlink-leftover-refused-without-main-root", "hooks/cleanup-orphan-dir.js");
test("gitlink-leftover-refused-without-main-root", () => {
  const dir = leftover(6000);
  assertRefused(cleanup(["--force-if-not-registered", dir]), dir);
});
caseEnd();

caseBegin("gitlink-leftover-refused-with-other-main-root", "hooks/cleanup-orphan-dir.js");
test("gitlink-leftover-refused-with-other-main-root", () => {
  const other = F.makeRepo(path.join(SB, "repos", "other"));
  const dir = leftover(3);
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", other, dir]), dir);
});
caseEnd();

caseBegin("gitlink-leftover-refused-without-force", "hooks/cleanup-orphan-dir.js");
test("gitlink-leftover-refused-without-force", () => {
  const dir = leftover(3);
  assertRefused(cleanup(["--expect-main-root", MAIN, dir]), dir);
});
caseEnd();

caseBegin("plain-dir-over-scan-cap-still-refused", "hooks/cleanup-orphan-dir.js");
test("plain-dir-over-scan-cap-still-refused", () => {
  const dir = path.join(BASE, "plain-big");
  fill(dir, 6000);
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
  assert.ok(/5000/.test(cleanup(["--force-if-not-registered", dir]).err), "the generic path keeps the cap");
});
caseEnd();

caseBegin("live-linked-worktree-refused", "hooks/cleanup-orphan-dir.js");
test("live-linked-worktree-refused", () => {
  const dir = F.addWorktree(MAIN, path.join(BASE, "live"), "feature/live");
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
});
caseEnd();

caseBegin("git-directory-refused", "hooks/cleanup-orphan-dir.js");
test("git-directory-refused", () => {
  const dir = F.makeRepo(path.join(BASE, "own-repo"));
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", dir, dir]), dir);
});
caseEnd();

caseBegin("nested-git-in-leftover-refused", "hooks/cleanup-orphan-dir.js");
test("nested-git-in-leftover-refused", () => {
  const dir = leftover(3);
  fs.mkdirSync(path.join(dir, "vendor", "lib", ".git"), { recursive: true });
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
});
caseEnd();

caseBegin("target-outside-base-refused", "hooks/cleanup-orphan-dir.js");
test("target-outside-base-refused", () => {
  const dir = F.makeLeftover(MAIN, path.join(SB, "outside", "left"), "feature/outside").leftover;
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
});
caseEnd();

caseBegin("unknown-gitlink-refused", "hooks/cleanup-orphan-dir.js");
test("unknown-gitlink-refused", () => {
  const dir = path.join(BASE, "unknown");
  F.writeGitlink(dir, path.join(SB, "nowhere", ".git", "worktrees", "unknown").replace(/\\/g, "/"));
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
});
caseEnd();

// D1-6: the capped-free path never follows a directory link. A junction (a plain dir symlink off
// Windows) points outside the leftover at a tree holding a `.git`: following it would refuse the
// leftover, and deleting through it would empty the target. The link itself goes with the leftover.
caseBegin("leftover-dir-link-not-followed", "hooks/cleanup-orphan-dir.js");
test("leftover-dir-link-not-followed", () => {
  const outside = path.join(SB, "link-target");
  fs.mkdirSync(path.join(outside, "repo", ".git"), { recursive: true });
  fs.writeFileSync(path.join(outside, "keep.txt"), "keep");
  const dir = leftover(3);
  fs.symlinkSync(outside, path.join(dir, "linked"), "junction");
  assertDeleted(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
  assert.ok(fs.existsSync(path.join(outside, "keep.txt")), "the link target's files must survive");
  assert.ok(fs.existsSync(path.join(outside, "repo", ".git")), "the link target's .git must survive");
});
caseEnd();

// D1-6: a main root exists only when the common dir is named `.git`; a bare repo has none.
caseBegin("bare-repo-leftover-refused", "hooks/cleanup-orphan-dir.js");
test("bare-repo-leftover-refused", () => {
  const bare = path.join(SB, "repos", "bare.git");
  F.git(["clone", "-q", "--bare", MAIN, bare], SB);
  F.git(["-C", bare, "config", "core.hooksPath", "/dev/null"], SB);
  const dir = F.makeLeftover(bare, path.join(BASE, "bare-left"), "feature/bare-left").leftover;
  for (const root of [bare, path.dirname(bare)]) {
    assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", root, dir]), dir);
  }
});
caseEnd();

// D1-6: an unreadable subdir refuses the capped-free path. Windows has no mode bit that denies
// readdir to the owner, and root reads through any mode, so the case runs on POSIX non-root only.
const UNREADABLE_SKIP = process.platform === "win32" ? "win32: chmod cannot deny readdir"
  : (process.getuid && process.getuid() === 0) ? "root reads through mode 000" : false;
caseBegin("leftover-unreadable-subdir-refused", "hooks/cleanup-orphan-dir.js");
test("leftover-unreadable-subdir-refused", { skip: UNREADABLE_SKIP }, () => {
  const dir = leftover(3);
  const locked = path.join(dir, "locked");
  fs.mkdirSync(locked);
  fs.writeFileSync(path.join(locked, "f.txt"), "x");
  fs.chmodSync(locked, 0o000);
  try {
    assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", MAIN, dir]), dir);
  } finally {
    fs.chmodSync(locked, 0o755);
  }
});
caseEnd();

caseBegin("main-root-flag-without-value-refused", "hooks/cleanup-orphan-dir.js");
test("main-root-flag-without-value-refused", () => {
  const dir = leftover(0);
  assertRefused(cleanup(["--force-if-not-registered", dir, "--expect-main-root"]), dir);
});
caseEnd();

// #2875: git's own worktree list is the second opinion. The admin dir's back-reference is respelled
// through a junction, so the path-string scan calls the target an unregistered leftover while git
// (after realpath) still lists it as a registered worktree of MAIN.
caseBegin("registered-worktree-missed-by-scan-refused", "hooks/cleanup-orphan-dir.js");
test("registered-worktree-missed-by-scan-refused", () => {
  const repo = F.makeRepo(path.join(SB, "repos", "respell"));
  const dir = F.addWorktree(repo, path.join(BASE, "respell-live"), "feature/respell-live");
  const alias = path.join(SB, "alias-respell");
  fs.symlinkSync(dir, alias, "junction");
  const admin = path.join(repo, ".git", "worktrees", fs.readdirSync(path.join(repo, ".git", "worktrees"))[0]);
  fs.writeFileSync(path.join(admin, "gitdir"), path.join(alias, ".git").replace(/\\/g, "/") + "\n");
  const { leftoverRefusal } = require(F.rel("hooks/cleanup-orphan-dir/leftover"));
  assert.ok(/registered worktree/.test(leftoverRefusal(dir, repo) || ""), "git's list must catch what the scan missed");
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", repo, dir]), dir);
});
caseEnd();

// #2875: when git cannot list the main root's worktrees the check fails closed.
caseBegin("main-root-git-failure-refused", "hooks/cleanup-orphan-dir.js");
test("main-root-git-failure-refused", () => {
  const repo = F.makeRepo(path.join(SB, "repos", "brokengit"));
  const dir = F.makeLeftover(repo, path.join(BASE, "broken-left"), "feature/broken-left").leftover;
  fs.appendFileSync(path.join(repo, ".git", "config"), "\n[broken\n");
  const { leftoverRefusal } = require(F.rel("hooks/cleanup-orphan-dir/leftover"));
  assert.ok(/cannot list worktrees/.test(leftoverRefusal(dir, repo) || ""), "git failure must refuse");
  assertRefused(cleanup(["--force-if-not-registered", "--expect-main-root", repo, dir]), dir);
});
caseEnd();
