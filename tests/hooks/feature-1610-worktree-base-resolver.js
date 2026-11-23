"use strict";
// Tests: hooks/lib/worktree-base.js
// Tags: feature-1610, feature-1849, worktree-base, resolver, worktree, in-repo-base, path-traversal, config-dependent, scope:issue-specific, TL2, pwsh-not-required
// #1610 / #1849: one resolver owns the worktree base. Unset/empty WORKTREE_BASE_DIR means the
// repo's own <main>/.claude/worktrees; an explicit value is one shared base, resolved against
// the home directory (never the CWD) so main, linked worktree and worker all agree.
// Every case runs in a child process with HOME/USERPROFILE and the global .env (AGENTS_MAIN_ROOT)
// pinned to fixture dirs, and WORKTREE_BASE_DIR pinned per case.
// The bin/worktree-base CLI cases live in tests/bin/feature-1610-worktree-base-cli.sh.
// TL3 gap: a real worker-dispatch child that receives WORKTREE_BASE_DIR through envPassthrough.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");

const restoreIsolation = isolate();
const SB = F.makeBase("f1610wb-");
after(() => {
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

const LIB = F.rel("hooks/lib/worktree-base.js");
const HOME = path.join(SB, "home");
const CONF = path.join(SB, "conf");
const CONF_WITH_ENV = path.join(SB, "conf-env");
fs.mkdirSync(HOME, { recursive: true });
fs.mkdirSync(CONF, { recursive: true });
fs.mkdirSync(CONF_WITH_ENV, { recursive: true });
fs.writeFileSync(path.join(CONF_WITH_ENV, ".env"), `WORKTREE_BASE_DIR=${path.join(SB, "from-dotenv").replace(/\\/g, "/")}\n`);
const MAIN = F.makeRepo(path.join(SB, "repos", "main"));
const LINKED = F.addWorktree(MAIN, path.join(SB, "linked", "main"), "feature/linked");
const SUBDIR = path.join(MAIN, "sub", "deeper");
fs.mkdirSync(SUBDIR, { recursive: true });
const OUTSIDE = path.join(SB, "not-a-repo");
fs.mkdirSync(OUTSIDE);
const DEFAULT_BASE = path.join(MAIN, ".claude", "worktrees");
const WIN = process.platform === "win32";

// base: undefined deletes WORKTREE_BASE_DIR; conf picks the global .env directory.
function childEnv(base, conf = CONF) {
  const env = Object.assign({}, process.env, { HOME, USERPROFILE: HOME, AGENTS_MAIN_ROOT: conf });
  delete env.WORKTREE_BASE_DIR;
  if (base !== undefined) env.WORKTREE_BASE_DIR = base;
  return env;
}

const RESOLVE_SRC = [
  "const m = require(process.argv[1]);",
  "const r = m.resolveWorktreeBase(process.argv[2]);",
  "process.stdout.write(JSON.stringify(r));",
].join("\n");

function resolve(repoDir, base, opts = {}) {
  const r = F.runNode(["-e", RESOLVE_SRC, LIB, repoDir], { cwd: opts.cwd || repoDir, env: childEnv(base, opts.conf) });
  if (/Cannot find module/.test(r.err)) throw new Error(`NOT YET IMPLEMENTED: ${LIB}`);
  assert.strictEqual(r.rc, 0, `stderr: ${r.err}`);
  return JSON.parse(r.out);
}

function inRepo(target, mainDir) {
  const m = F.need("hooks/lib/worktree-base.js", "isInRepoBase");
  return m(target, mainDir);
}

function assertBase(r, expected, source) {
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.ok(F.samePath(r.base, expected), `base ${r.base} != ${expected}`);
  assert.strictEqual(r.source, source);
}

caseBegin("unset-empty-blank-resolve-to-in-repo-default", "hooks/lib/worktree-base.js");
test("unset-empty-blank-resolve-to-in-repo-default", () => {
  for (const base of [undefined, "", "   "]) {
    const r = resolve(MAIN, base);
    assertBase(r, DEFAULT_BASE, "default");
    assert.ok(F.samePath(r.mainDir, MAIN), `mainDir ${r.mainDir}`);
  }
});
caseEnd();

caseBegin("explicit-absolute-is-shared-base", "hooks/lib/worktree-base.js");
test("explicit-absolute-is-shared-base", () => {
  const shared = path.join(SB, "shared-base");
  assertBase(resolve(MAIN, shared), shared, "explicit");
});
caseEnd();

caseBegin("explicit-base-shared-across-repos", "hooks/lib/worktree-base.js");
test("explicit-base-shared-across-repos", () => {
  const shared = path.join(SB, "shared-multi");
  const alpha = F.makeRepo(path.join(SB, "repos", "alpha"));
  const beta = F.makeRepo(path.join(SB, "repos", "beta"));
  const ra = resolve(alpha, shared);
  const rb = resolve(beta, shared);
  assertBase(ra, shared, "explicit");
  assertBase(rb, shared, "explicit");
  assert.ok(F.samePath(ra.mainDir, alpha) && F.samePath(rb.mainDir, beta), "each repo keeps its own mainDir");
  assert.ok(!F.samePath(ra.base, path.join(alpha, ".claude", "worktrees")), "no per-repo default when explicit");
});
caseEnd();

caseBegin("explicit-tilde-expands-to-home", "hooks/lib/worktree-base.js");
test("explicit-tilde-expands-to-home", () => {
  assertBase(resolve(MAIN, "~/wt-tilde"), path.join(HOME, "wt-tilde"), "explicit");
});
caseEnd();

caseBegin("explicit-posix-drive-path-normalized", "hooks/lib/worktree-base.js");
test("explicit-posix-drive-path-normalized", { skip: WIN ? false : "win32 only: /c/... form" }, () => {
  const native = path.join(SB, "posix-form");
  const posix = "/" + native[0].toLowerCase() + native.slice(2).replace(/\\/g, "/");
  assertBase(resolve(MAIN, posix), native, "explicit");
});
caseEnd();

caseBegin("process-env-beats-dotenv", "hooks/lib/worktree-base.js");
test("process-env-beats-dotenv", () => {
  const exported = path.join(SB, "from-export");
  assertBase(resolve(MAIN, exported, { conf: CONF_WITH_ENV }), exported, "explicit");
  assertBase(resolve(MAIN, undefined, { conf: CONF_WITH_ENV }), path.join(SB, "from-dotenv"), "explicit");
});
caseEnd();

caseBegin("relative-explicit-resolves-against-home-from-any-cwd", "hooks/lib/worktree-base.js");
test("relative-explicit-resolves-against-home-from-any-cwd", () => {
  for (const [value, expected] of [["wt", path.join(HOME, "wt")], ["./wt", path.join(HOME, "wt")], ["../wt", path.join(SB, "wt")]]) {
    for (const from of [MAIN, LINKED, SUBDIR]) {
      assertBase(resolve(from, value, { cwd: from }), expected, "explicit");
    }
  }
});
caseEnd();

caseBegin("windows-drive-relative-and-root-relative-fixed", "hooks/lib/worktree-base.js");
test("windows-drive-relative-and-root-relative-fixed", { skip: WIN ? false : "win32 only: drive forms" }, () => {
  const drive = HOME.slice(0, 2);
  for (const from of [MAIN, SUBDIR]) {
    assertBase(resolve(from, `${drive}wt`, { cwd: from }), `${drive}\\wt`, "explicit");
    assertBase(resolve(from, "\\wt", { cwd: from }), `${drive}\\wt`, "explicit");
  }
});
caseEnd();

caseBegin("linked-worktree-and-subdir-normalize-to-main-root", "hooks/lib/worktree-base.js");
test("linked-worktree-and-subdir-normalize-to-main-root", () => {
  for (const from of [LINKED, SUBDIR]) {
    const r = resolve(from, undefined);
    assert.ok(F.samePath(r.mainDir, MAIN), `mainDir ${r.mainDir}`);
    assertBase(r, DEFAULT_BASE, "default");
  }
});
caseEnd();

caseBegin("outside-repo-is-not-ok", "hooks/lib/worktree-base.js");
test("outside-repo-is-not-ok", () => {
  const r = resolve(OUTSIDE, undefined);
  assert.strictEqual(r.ok, false);
  assert.ok(typeof r.reason === "string" && r.reason.length > 0, JSON.stringify(r));
  assert.strictEqual(r.base, undefined, "a failed resolve names no base");
});
caseEnd();

caseBegin("in-repo-base-constant-exported", "hooks/lib/worktree-base.js");
test("in-repo-base-constant-exported", () => {
  const m = F.tryRequire("hooks/lib/worktree-base.js");
  assert.ok(m, "NOT YET IMPLEMENTED: hooks/lib/worktree-base.js");
  assert.strictEqual(m.IN_REPO_BASE_REL, ".claude/worktrees");
});
caseEnd();

caseBegin("is-in-repo-base-allows-below-base", "hooks/lib/worktree-base.js");
test("is-in-repo-base-allows-below-base", () => {
  assert.strictEqual(inRepo(path.join(DEFAULT_BASE, "task", "main"), MAIN), true);
  assert.strictEqual(inRepo(path.join(DEFAULT_BASE, "task"), MAIN), true);
  assert.strictEqual(inRepo(DEFAULT_BASE.replace(/\\/g, "/") + "/task/main", MAIN), true, "forward slashes");
  assert.strictEqual(inRepo(path.join(DEFAULT_BASE, "task", "main").toUpperCase(), MAIN), true, "case differs");
  assert.strictEqual(inRepo(path.join(DEFAULT_BASE, "t", "..", "t2", "main"), MAIN), true, ".. staying inside");
});
caseEnd();

caseBegin("is-in-repo-base-rejects-base-siblings-and-traversal", "hooks/lib/worktree-base.js");
test("is-in-repo-base-rejects-base-siblings-and-traversal", () => {
  const other = path.join(SB, "repos", "other");
  for (const target of [
    DEFAULT_BASE,
    DEFAULT_BASE + path.sep,
    path.join(MAIN, ".claude", "worktrees-x", "task"),
    path.join(MAIN, ".claude", "settings.json"),
    path.join(MAIN, ".claude"),
    path.join(MAIN, "src", "x"),
    path.join(DEFAULT_BASE, "..", "evil"),
    path.join(DEFAULT_BASE, "t", "..", "..", "..", "escape"),
    DEFAULT_BASE + "/../../outside",
    path.join(other, ".claude", "worktrees", "task", "other"),
  ]) {
    assert.strictEqual(inRepo(target, MAIN), false, target);
  }
});
caseEnd();

// The `..` prefix test must judge a path segment, not a string prefix: `<main>/..wt` is inside.
caseBegin("in-repo-relative-boundaries", "hooks/lib/worktree-base.js");
test("in-repo-relative-boundaries", () => {
  const rel = F.need("hooks/lib/worktree-base.js", "inRepoRelative");
  const rows = [
    ["base equals main", MAIN, MAIN, null],
    ["default base", DEFAULT_BASE, MAIN, ".claude/worktrees"],
    ["outside repo", OUTSIDE, MAIN, null],
    ["sibling via ..", path.join(MAIN, "..", "x"), MAIN, null],
    ["dot-dot-named dir inside", path.join(MAIN, "..wt"), MAIN, "..wt"],
    ["nested native separators", path.join(MAIN, "a", "b"), MAIN, "a/b"],
    ["empty base", "", MAIN, null],
    ["unset base", undefined, MAIN, null],
    ["empty main", DEFAULT_BASE, "", null],
    ["unset main", DEFAULT_BASE, undefined, null],
  ];
  if (WIN) rows.push(["backslash input", MAIN.replace(/\//g, "\\") + "\\x\\y", MAIN.replace(/\\/g, "/"), "x/y"]);
  for (const [label, base, mainDir, expected] of rows) {
    assert.strictEqual(rel(base, mainDir), expected, label);
  }
});
caseEnd();

const EXPLICIT_SRC = "process.stdout.write(JSON.stringify(require(process.argv[1]).explicitWorktreeBase()));";

caseBegin("explicit-worktree-base-unset-empty-and-value", "hooks/lib/worktree-base.js");
test("explicit-worktree-base-unset-empty-and-value", () => {
  const rows = [
    [undefined, null],
    ["", null],
    ["   ", null],
    ["wt-explicit", path.join(HOME, "wt-explicit")],
    [path.join(SB, "abs-explicit"), path.join(SB, "abs-explicit")],
  ];
  for (const [value, expected] of rows) {
    const r = F.runNode(["-e", EXPLICIT_SRC, LIB], { cwd: OUTSIDE, env: childEnv(value) });
    assert.strictEqual(r.rc, 0, `stderr: ${r.err}`);
    const got = JSON.parse(r.out);
    if (expected === null) assert.strictEqual(got, null, `value ${JSON.stringify(value)}`);
    else assert.ok(F.samePath(got, expected), `value ${value}: ${got} != ${expected}`);
  }
});
caseEnd();
