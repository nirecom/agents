"use strict";
// Tests: bin/worktree-write-notes.js, hooks/lib/worktree-base.js
// Tags: feature-3138, worktree-notes, exclude, in-repo-base, symlink, junction, config-dependent, scope:issue-specific, TL2, pwsh-not-required
// TL3 gap: a live /worktree-start whose main `git status` is read after the notes step; here the
// notes CLI runs against fixture repos with HOME/USERPROFILE/AGENTS_MAIN_ROOT pinned.
//
// #3138: the base registered in <main>/.git/info/exclude comes from inRepoRelative, which now
// resolves real paths. A base outside the repo is never registered and is no error; a base that a
// link redirects (to a tracked repo directory) is never registered either, so the link target is
// not hidden from git. First-run true / second-run false is pinned by
// tests/hooks/feature-1610-write-notes-in-repo-base.js and not repeated here.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const F = require("../lib/worktree-leftover-fixture");

const restore = isolate();
const SB = F.makeBase("f3138be-");
after(() => {
  restore();
  fs.rmSync(SB, { recursive: true, force: true });
});

const CLI = F.rel("bin/worktree-write-notes.js");
const HOME = path.join(SB, "home");
const CONF = path.join(SB, "conf");
fs.mkdirSync(HOME, { recursive: true });
fs.mkdirSync(CONF, { recursive: true });
const fwd = (p) => p.replace(/\\/g, "/");

// Same link policy as feature-3138-in-repo-base-realpath.js: junction on Windows, symlink
// elsewhere; only a win32 probe failing with one of these codes may skip.
const SKIP_CODES = new Set(["EPERM", "EACCES", "ENOSYS", "EOPNOTSUPP"]);
const link = (target, at) => fs.symlinkSync(target, at, "junction");
let LINK_SKIP = false;
try {
  fs.mkdirSync(path.join(SB, "probe-target"));
  link(path.join(SB, "probe-target"), path.join(SB, "probe-link"));
} catch (e) {
  if (process.platform === "win32" && SKIP_CODES.has(e.code)) LINK_SKIP = `directory junction unavailable here (${e.code})`;
  else throw e;
}
if (LINK_SKIP) process.stdout.write(`# skip link cases: ${LINK_SKIP}\n`);

// base: undefined deletes WORKTREE_BASE_DIR from the child env.
function notes(main, wt, { base } = {}) {
  const env = Object.assign({}, process.env, { HOME, USERPROFILE: HOME, AGENTS_MAIN_ROOT: CONF, COPIED_JSON: "" });
  delete env.WORKTREE_BASE_DIR;
  delete env.CLAUDE_CODE_SESSION_ID;
  if (base !== undefined) env.WORKTREE_BASE_DIR = base;
  fs.mkdirSync(wt, { recursive: true });
  const r = F.runNode([CLI, fwd(main), fwd(wt), "feature/n", "", ""], { cwd: main, env });
  let json = null;
  try {
    json = JSON.parse(r.out.trim().split(/\r?\n/).pop());
  } catch (_e) {
    json = null;
  }
  return Object.assign(r, { json });
}

function excludeLines(main) {
  try {
    return fs.readFileSync(path.join(main, ".git", "info", "exclude"), "utf8").split(/\r?\n/).map((l) => l.trim());
  } catch (_e) {
    return [];
  }
}

// A repo whose tracked `src/` holds a committed file, so hiding it would be visible.
function repoWithTrackedSrc(dir) {
  const main = F.makeRepo(dir);
  fs.mkdirSync(path.join(main, "src"));
  fs.writeFileSync(path.join(main, "src", "kept.txt"), "tracked\n");
  F.git(["-C", main, "add", "src/kept.txt"]);
  F.git(["-C", main, "commit", "-q", "--no-verify", "-m", "src"]);
  return main;
}

function assertNotRegistered(r, main, label, forbidden) {
  assert.equal(r.rc, 0, `${label}: rc=${r.rc} err=${r.err}`);
  assert.ok(r.json, `${label}: stdout is JSON: ${r.out}`);
  assert.equal(r.json.baseExcludeAdded, false, `${label}: ${r.out}`);
  assert.ok(!r.json.baseExcludeError, `${label}: no baseExcludeError: ${r.out}`);
  assert.deepEqual(r.json.errors, [], `${label}: no errors`);
  const lines = excludeLines(main);
  for (const re of forbidden) assert.ok(!lines.some((l) => re.test(l)), `${label}: ${re} absent from ${JSON.stringify(lines)}`);
  assert.ok(lines.includes("WORKTREE_NOTES.md"), `${label}: the notes exclude line is still written`);
}

// check-ignore exits 1 when the path is not ignored.
function assertSrcVisible(main) {
  const ci = spawnSync("git", ["-C", main, "check-ignore", "-q", "--no-index", "src/new.txt"], { encoding: "utf8", timeout: 30000 });
  assert.equal(ci.status, 1, `the link target src/ must stay visible to git (check-ignore rc=${ci.status} ${ci.stderr})`);
}

caseBegin("out-of-repo-base-is-not-registered-and-no-error", "bin/worktree-write-notes.js");
test("out-of-repo-base-is-not-registered-and-no-error", () => {
  const main = F.makeRepo(path.join(SB, "a1", "main"));
  const shared = path.join(SB, "a1", "shared");
  fs.mkdirSync(shared, { recursive: true });
  for (const run of ["first", "second"]) {
    const r = notes(main, path.join(SB, "a1", `wt-${run}`), { base: fwd(shared) });
    assertNotRegistered(r, main, `${run} run`, [/shared/, /^\/?\.claude\/worktrees\/?$/, /^\.\./]);
  }
});
caseEnd();

caseBegin("link-redirected-explicit-base-is-not-registered", "hooks/lib/worktree-base.js");
test("link-redirected-explicit-base-is-not-registered", { skip: LINK_SKIP }, () => {
  F.need("hooks/lib/path-real-fold.js", "realResolve");
  const main = repoWithTrackedSrc(path.join(SB, "b1", "main"));
  const base = path.join(main, ".wt-link");
  link(path.join(main, "src"), base);
  const r = notes(main, path.join(SB, "b1", "wt"), { base: fwd(base) });
  assertNotRegistered(r, main, "explicit base linked to src/", [/^\/?\.wt-link\/?$/, /^\/?src\/?$/]);
  assertSrcVisible(main);
});
caseEnd();

caseBegin("link-redirected-default-base-is-not-registered", "hooks/lib/worktree-base.js");
test("link-redirected-default-base-is-not-registered", { skip: LINK_SKIP }, () => {
  F.need("hooks/lib/path-real-fold.js", "realResolve");
  const main = repoWithTrackedSrc(path.join(SB, "b2", "main"));
  fs.mkdirSync(path.join(main, ".claude"));
  link(path.join(main, "src"), path.join(main, ".claude", "worktrees"));
  const r = notes(main, path.join(SB, "b2", "wt"));
  assertNotRegistered(r, main, "default base linked to src/", [/^\/?\.claude\/worktrees\/?$/, /^\/?src\/?$/]);
  assertSrcVisible(main);
});
caseEnd();
