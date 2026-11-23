"use strict";
// Tests: hooks/lib/path-real-fold.js, hooks/lib/worktree-base.js, hooks/enforce-worktree/main-worktree-allows/worktree-command.js, hooks/enforce-worktree/main-worktree-allows/new-item.js
// Tags: feature-3138, worktree-base, in-repo-base, realpath, symlink, junction, letter-case, path-traversal, security, fail-closed, scope:issue-specific, TL2, pwsh-not-required
// TL3 gap: no live Claude Code session drives enforce-worktree here; the classifiers are called
// directly. A real case-sensitive APFS volume on macOS and a case-insensitive mount on Linux are
// not provisioned: the real-name case measures the temp file system and skips those combinations.
//
// #3138: the in-repo base check resolves real paths. A base that a link redirects (inside or
// outside the repo, or through a linked `.claude`) is refused; a link made inside the base is judged
// by where it really points, `..` after a link climbs from the link's target, and any resolution
// error is a refusal (fail-closed). Letter case folds only on win32 / darwin (foldsCase).

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const F = require("../lib/worktree-leftover-fixture");
const { platformRuleMismatch, fsFoldsCase } = require("./helpers/fs-case-probe");

const restore = isolate();
const { isAllowedWorktreeCommand } = require("../../hooks/enforce-worktree/main-worktree-allows/worktree-command");
const { isAllowedNewItemCommand } = require("../../hooks/enforce-worktree/main-worktree-allows/new-item");

const PRF = "hooks/lib/path-real-fold.js";
const prf = (name) => F.need(PRF, name);
const wb = (name) => F.need("hooks/lib/worktree-base.js", name);

const SB = F.makeBase("f3138rp-");
after(() => {
  restore();
  fs.rmSync(SB, { recursive: true, force: true });
});

const fwd = (p) => String(p).replace(/\\/g, "/");
const FOLDS = process.platform === "win32" || process.platform === "darwin";
const MAIN = F.makeRepo(path.join(SB, "main"));
const M = fwd(MAIN);
const BASE = path.join(MAIN, ".claude", "worktrees");
const B = fwd(BASE);
fs.mkdirSync(path.join(BASE, "real-task"), { recursive: true });
fs.mkdirSync(path.join(MAIN, "src"), { recursive: true });

// Directory links: a junction on Windows (no admin rights or developer mode), a symlink elsewhere
// (the type argument is ignored). Only a win32 probe failing with one of these codes may skip.
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

// One repo per redirected-base shape, built only when links work.
const R = {};
if (!LINK_SKIP) {
  const repoWithBaseLink = (name, linkTarget, linkAt = [".claude", "worktrees"]) => {
    const repo = F.makeRepo(path.join(SB, name));
    fs.mkdirSync(path.join(repo, ...linkAt.slice(0, -1)), { recursive: true });
    fs.mkdirSync(linkTarget(repo), { recursive: true });
    link(linkTarget(repo), path.join(repo, ...linkAt));
    return repo;
  };
  R.inRepo = repoWithBaseLink("r-inrepo", (r) => path.join(r, "src-wt"));
  R.outside = repoWithBaseLink("r-outside", () => path.join(SB, "outside-base"));
  R.claudeLinked = repoWithBaseLink("r-claude", () => path.join(SB, "claude-elsewhere"), [".claude"]);
  fs.mkdirSync(path.join(SB, "claude-elsewhere", "worktrees"), { recursive: true });
  R.dangling = repoWithBaseLink("r-dangling", () => path.join(SB, "gone"));
  fs.rmSync(path.join(SB, "gone"), { recursive: true, force: true });
  link(path.join(MAIN, "src"), path.join(BASE, "lnk-tracked"));
  link(path.join(BASE, "real-task"), path.join(BASE, "lnk-inside"));
}
const linkOpt = { skip: LINK_SKIP };

caseBegin("fold-rule-is-decided-by-platform", "hooks/lib/path-real-fold.js");
test("fold-rule-is-decided-by-platform", () => {
  const foldsCase = prf("foldsCase");
  assert.equal(foldsCase("win32"), true);
  assert.equal(foldsCase("darwin"), true);
  assert.equal(foldsCase("linux"), false);
  assert.equal(foldsCase(), FOLDS, "default argument is process.platform");
  const foldKey = prf("foldKey");
  const raw = path.join(SB, "Mixed", "Case") + path.sep;
  const expected = fwd(path.resolve(raw)).replace(/\/+$/, "");
  assert.equal(foldKey(raw), FOLDS ? expected.toLowerCase() : expected, "resolved, forward slashes, no trailing slash");
});
caseEnd();

caseBegin("plain-in-base-targets-keep-their-verdicts", "hooks/lib/worktree-base.js");
test("plain-in-base-targets-keep-their-verdicts", () => {
  const isInRepoBase = wb("isInRepoBase");
  prf("realResolve");
  assert.equal(isInRepoBase(`${B}/my-task/main`, MAIN), true, "uncreated target below an existing base");
  assert.equal(isInRepoBase(`${B}/real-task/main`, MAIN), true, "below an existing directory in the base");
  const fresh = F.makeRepo(path.join(SB, "fresh"));
  assert.equal(isInRepoBase(`${fwd(fresh)}/.claude/worktrees/t/main`, fresh), true, "base not created yet");
  for (const [label, t] of Object.entries({
    "base itself": B, "base with trailing slash": `${B}/`, "sibling-prefix base": `${M}/.claude/worktrees-x/t`,
    "traversal out of the base": `${B}/../../src/x`, "plain repo path": `${M}/src/x`,
  })) assert.equal(isInRepoBase(t, MAIN), false, label);
});
caseEnd();

// Git Bash hands win32 paths over as /c/...; realResolve must normalizeCwd before walking them.
const toPosixDrive = (p) => fwd(p).replace(/^([A-Za-z]):/, (_, d) => `/${d.toLowerCase()}`);
const POSIX_SKIP = process.platform === "win32" ? false : `POSIX drive form (/c/...) is a win32-only input (platform=${process.platform})`;
if (POSIX_SKIP) process.stdout.write(`# skip posix-drive case: ${POSIX_SKIP}\n`);
caseBegin("posix-drive-form-in-base-is-allowed-on-win32", "hooks/lib/path-real-fold.js");
test("posix-drive-form-in-base-is-allowed-on-win32", { skip: POSIX_SKIP }, () => {
  const isInRepoBase = wb("isInRepoBase");
  const realResolve = prf("realResolve");
  const pm = toPosixDrive(MAIN);
  const pt = `${toPosixDrive(BASE)}/my-task/main`;
  assert.match(pm, /^\/[a-z]\//, "fixture: main dir in /c/... form");
  assert.ok(F.samePath(realResolve(toPosixDrive(BASE)), BASE), "realResolve walks a /c/... path");
  assert.equal(isInRepoBase(pt, pm), true, "target and main dir both /c/...");
  assert.equal(isInRepoBase(pt, MAIN), true, "/c/... target, C:/ main dir");
  assert.equal(isInRepoBase(`${B}/my-task/main`, pm), true, "C:/ target, /c/... main dir");
  assert.equal(isInRepoBase(`${toPosixDrive(BASE)}/../../src/x`, pm), false, "traversal out of the base stays refused");
});
caseEnd();

caseBegin("dot-dot-after-an-uncreated-part-is-refused", "hooks/lib/path-real-fold.js");
test("dot-dot-after-an-uncreated-part-is-refused", () => {
  const realResolve = prf("realResolve");
  assert.throws(() => realResolve(`${B}/new/../../x`), "`..` after a part that does not exist");
  assert.equal(wb("isInRepoBase")(`${B}/new/../../x`, MAIN), false, "(iii) the classifier refuses it");
  assert.equal(wb("isInRepoBase")(`${B}/new/../other`, MAIN), false, "fail-closed even when it would stay inside");
});
caseEnd();

caseBegin("redirected-base-is-refused", "hooks/lib/worktree-base.js");
test("redirected-base-is-refused", linkOpt, () => {
  const isInRepoBase = wb("isInRepoBase");
  const inRepoRelative = wb("inRepoRelative");
  prf("realResolve");
  for (const [label, repo] of Object.entries({
    "base links to a repo directory": R.inRepo, "base links outside the repo": R.outside,
    ".claude itself is a link": R.claudeLinked, "base is a dangling link": R.dangling,
  })) {
    assert.equal(isInRepoBase(`${fwd(repo)}/.claude/worktrees/t/main`, repo), false, label);
    assert.equal(inRepoRelative(path.join(repo, ".claude", "worktrees"), repo), null, `inRepoRelative: ${label}`);
  }
});
caseEnd();

caseBegin("links-inside-the-base-are-judged-by-their-target", "hooks/lib/worktree-base.js");
test("links-inside-the-base-are-judged-by-their-target", linkOpt, () => {
  const isInRepoBase = wb("isInRepoBase");
  const realResolve = prf("realResolve");
  assert.equal(isInRepoBase(`${B}/lnk-tracked/x`, MAIN), false, "(i) a link to a tracked directory");
  assert.equal(isInRepoBase(`${B}/lnk-tracked/../x`, MAIN), false, "(i) `..` climbs from the link target");
  assert.ok(F.samePath(realResolve(`${B}/lnk-tracked/..`), MAIN), "`..` after a link is the target's parent");
  assert.equal(isInRepoBase(`${B}/lnk-inside/x`, MAIN), true, "(ii) a link to another directory in the base");
});
caseEnd();

caseBegin("junction-resolves-to-the-real-name", "hooks/lib/path-real-fold.js");
test("junction-resolves-to-the-real-name", linkOpt, () => {
  const realResolve = prf("realResolve");
  const real = path.join(SB, "Real-Target");
  fs.mkdirSync(real);
  link(real, path.join(SB, "jn"));
  const got = realResolve(path.join(SB, "jn"));
  assert.equal(fwd(got), fwd(real), "the link resolves to the target, spelled as on disk");
  assert.ok(!String(got).startsWith("\\\\?\\"), "no \\\\?\\ prefix");
  assert.throws(() => realResolve(path.join(R.dangling, ".claude", "worktrees")), "a dangling link throws");
});
caseEnd();

caseBegin("real-name-normalization-follows-the-platform-rule", "hooks/lib/path-real-fold.js");
test("real-name-normalization-follows-the-platform-rule", { skip: platformRuleMismatch() }, () => {
  const realResolve = prf("realResolve");
  const inRepoRelative = wb("inRepoRelative");
  fs.mkdirSync(path.join(MAIN, "Wt-Base"), { recursive: true });
  const typed = `${M}/wt-base`;
  const expectedLeaf = FOLDS ? "Wt-Base" : "wt-base";
  assert.equal(path.basename(realResolve(typed)), expectedLeaf, "real spelling on a folding platform, typed spelling otherwise");
  assert.equal(inRepoRelative(typed, MAIN), expectedLeaf);
  assert.equal(inRepoRelative(`${typed}/Sub`, MAIN), `${expectedLeaf}/Sub`, "the uncreated tail keeps the typed spelling");
  const upper = `${M}/.CLAUDE/Worktrees/t/main`;
  assert.equal(wb("isInRepoBase")(upper, MAIN), FOLDS, "misspelled base: allowed only where case folds");
});
caseEnd();

// The stubs replace an fs or module function before the code under test loads, so they run in a child.
const KEY = `const key = (p) => path.resolve(String(p)).replace(/\\\\/g, "/").toLowerCase();`;

const CHILD_EACCES = `
const path = require("path"); const [root, target, mainDir, base] = process.argv.slice(1);
const prf = require(path.join(root, "hooks/lib/path-real-fold.js"));
prf.realResolve = () => { const e = new Error("EACCES: permission denied (stub)"); e.code = "EACCES"; throw e; };
const wb = require(path.join(root, "hooks/lib/worktree-base.js"));
process.stdout.write(JSON.stringify({ inBase: wb.isInRepoBase(target, mainDir), rel: wb.inRepoRelative(base, mainDir) }));`;

const CHILD_NO_ENTRY = `
const fs = require("fs"); const path = require("path"); const [root, target, mainDir, hideIn] = process.argv.slice(1);
${KEY}
const orig = fs.readdirSync;
fs.readdirSync = function (p, ...rest) { return key(p) === key(hideIn) ? [] : orig.call(this, p, ...rest); };
const prf = require(path.join(root, "hooks/lib/path-real-fold.js"));
const wb = require(path.join(root, "hooks/lib/worktree-base.js"));
let threw = null; try { prf.realResolve(target); } catch (e) { threw = String(e && e.message); }
process.stdout.write(JSON.stringify({ threw, inBase: wb.isInRepoBase(target, mainDir) }));`;

// lstat of <failAt> throws <code>; every other path is the real lstat.
const CHILD_LSTAT_ERROR = `
const fs = require("fs"); const path = require("path"); const [root, target, mainDir, failAt, code] = process.argv.slice(1);
${KEY}
const orig = fs.lstatSync;
fs.lstatSync = function (p, ...rest) {
  if (key(p) !== key(failAt)) return orig.call(this, p, ...rest);
  const e = new Error(code + ": stubbed lstat failure"); e.code = code; throw e;
};
const prf = require(path.join(root, "hooks/lib/path-real-fold.js"));
const wb = require(path.join(root, "hooks/lib/worktree-base.js"));
let threw = null; try { prf.realResolve(target); } catch (e) { threw = String(e && e.code); }
process.stdout.write(JSON.stringify({ threw, inBase: wb.isInRepoBase(target, mainDir) }));`;

// readdir of <dupIn> lists Wt-Dup and wt-dup (strings or Dirent clones of the real wt-dup entry).
const CHILD_DUP = `
const fs = require("fs"); const path = require("path"); const [root, dupIn] = process.argv.slice(1);
${KEY}
const orig = fs.readdirSync;
const rename = (d, name) => typeof d === "string" ? name : Object.assign(Object.create(Object.getPrototypeOf(d)), d, { name });
fs.readdirSync = function (p, ...rest) {
  const got = orig.call(this, p, ...rest);
  if (key(p) !== key(dupIn)) return got;
  const real = got.find((d) => (typeof d === "string" ? d : d.name) === "wt-dup");
  return [rename(real, "Wt-Dup"), rename(real, "wt-dup")];
};
const prf = require(path.join(root, "hooks/lib/path-real-fold.js"));
const leaf = (t) => { try { return path.basename(prf.realResolve(path.join(dupIn, t))); } catch (e) { return "THREW"; } };
process.stdout.write(JSON.stringify({ exact: leaf("wt-dup"), ambiguous: leaf("WT-DUP") }));`;

const CHILD_CWD = `
const path = require("path"); const [root] = process.argv.slice(1);
const prf = require(path.join(root, "hooks/lib/path-real-fold.js"));
process.stdout.write(JSON.stringify({ dot: prf.realResolve("."), base: prf.realResolve(".claude/worktrees"), up: prf.realResolve(".claude/worktrees/../..") }));`;

function child(code, args, opts = {}) {
  const r = F.runNode(["-e", code, F.ROOT, ...args], { timeout: 30000, ...opts });
  assert.equal(r.rc, 0, `child failed: ${r.err}`);
  return JSON.parse(r.out);
}

caseBegin("relative-input-resolves-from-the-process-cwd", "hooks/lib/path-real-fold.js");
test("relative-input-resolves-from-the-process-cwd", () => {
  prf("realResolve");
  const got = child(CHILD_CWD, [], { cwd: MAIN });
  const real = fs.realpathSync.native(MAIN);
  assert.ok(F.samePath(got.dot, real), `"." is the real path of the CWD: ${got.dot}`);
  assert.ok(F.samePath(got.base, BASE), `a relative base is joined to the CWD: ${got.base}`);
  assert.ok(F.samePath(got.up, real), `\`..\` climbs back to the CWD: ${got.up}`);
});
caseEnd();

// readdir lookup when several entries fold to the typed segment: an exact match wins. Real
// fold-duplicates exist only on a case-sensitive FS; the ambiguous (no exact match) branch is
// reachable only where lstat folds, so a readdir stub supplies the duplicates there.
const FS_FOLDS = fsFoldsCase();
const DUP_REAL_SKIP = FS_FOLDS ? "the temp file system folds case, so Wt-Dup and wt-dup cannot coexist" : false;
const DUP_STUB_SKIP = FS_FOLDS ? false : "lstat does not fold here, so a mis-cased segment never reaches the readdir lookup";
for (const why of [DUP_REAL_SKIP, DUP_STUB_SKIP]) if (why) process.stdout.write(`# skip readdir-dup case: ${why}\n`);

caseBegin("readdir-prefers-the-exact-entry-among-fold-duplicates", "hooks/lib/path-real-fold.js");
test("readdir-prefers-the-exact-entry-among-fold-duplicates", { skip: DUP_REAL_SKIP }, () => {
  const realResolve = prf("realResolve");
  const dup = path.join(SB, "dup-real");
  fs.mkdirSync(path.join(dup, "Wt-Dup"), { recursive: true });
  fs.mkdirSync(path.join(dup, "wt-dup"), { recursive: true });
  assert.equal(path.basename(realResolve(path.join(dup, "Wt-Dup"))), "Wt-Dup");
  assert.equal(path.basename(realResolve(path.join(dup, "wt-dup"))), "wt-dup");
});
caseEnd();

caseBegin("readdir-without-an-exact-entry-among-fold-duplicates-throws", "hooks/lib/path-real-fold.js");
test("readdir-without-an-exact-entry-among-fold-duplicates-throws", { skip: DUP_STUB_SKIP }, () => {
  prf("realResolve");
  const dup = path.join(SB, "dup-stub");
  fs.mkdirSync(path.join(dup, "wt-dup"), { recursive: true });
  const got = child(CHILD_DUP, [dup]);
  assert.equal(got.exact, "wt-dup", "the exact entry is chosen among fold duplicates");
  assert.equal(got.ambiguous, "THREW", "no exact entry among fold duplicates is not resolved");
});
caseEnd();

caseBegin("resolution-errors-fail-closed", "hooks/lib/worktree-base.js");
test("resolution-errors-fail-closed", () => {
  prf("realResolve");
  const target = `${B}/my-task/main`;
  assert.equal(wb("isInRepoBase")(target, MAIN), true, "control: allowed without a stub");
  const eacces = child(CHILD_EACCES, [target, MAIN, BASE]);
  assert.deepEqual(eacces, { inBase: false, rel: null }, "realResolve throwing EACCES refuses");
});
caseEnd();

caseBegin("non-enoent-lstat-errors-throw-and-refuse", "hooks/lib/path-real-fold.js");
test("non-enoent-lstat-errors-throw-and-refuse", () => {
  prf("realResolve");
  const target = `${B}/my-task/main`;
  for (const code of ["EACCES", "ENOTDIR"]) {
    const got = child(CHILD_LSTAT_ERROR, [target, MAIN, path.join(BASE, "my-task"), code]);
    assert.equal(got.threw, code, `${code} on lstat is rethrown, not treated as an uncreated part`);
    assert.equal(got.inBase, false, `${code}: the classifier refuses`);
  }
});
caseEnd();

const add = (t) => `git worktree add "${t}" -b feature/my-task`;
const ni = (p) => `New-Item -ItemType Directory -Path "${p}"`;

caseBegin("worktree-add-into-a-redirected-base-is-refused", "hooks/enforce-worktree/main-worktree-allows/worktree-command.js");
test("worktree-add-into-a-redirected-base-is-refused", linkOpt, () => {
  prf("realResolve");
  assert.equal(isAllowedWorktreeCommand(add(`${B}/my-task/main`), MAIN), true, "control: a plain base");
  for (const repo of [R.inRepo, R.outside, R.claudeLinked]) {
    assert.equal(isAllowedWorktreeCommand(add(`${fwd(repo)}/.claude/worktrees/t/main`), repo), false, repo);
  }
  assert.equal(isAllowedWorktreeCommand(add(`${B}/lnk-tracked/x`), MAIN), false, "through a link inside the base");
});
caseEnd();

caseBegin("new-item-into-a-redirected-base-is-refused", "hooks/enforce-worktree/main-worktree-allows/new-item.js");
test("new-item-into-a-redirected-base-is-refused", linkOpt, () => {
  prf("realResolve");
  assert.equal(isAllowedNewItemCommand(ni(`${B}/my-task/main`), MAIN), true, "control: a plain base");
  for (const repo of [R.inRepo, R.outside, R.claudeLinked]) {
    assert.equal(isAllowedNewItemCommand(ni(`${fwd(repo)}/.claude/worktrees/t/main`), repo), false, repo);
  }
  assert.equal(isAllowedNewItemCommand(ni(`${B}/lnk-tracked/x`), MAIN), false, "through a link inside the base");
});
caseEnd();

// readdir is counted only during realResolve; <deny>="deny" makes every readdir throw EACCES.
const CHILD_READDIR_COUNT = `
const fs = require("fs"); const path = require("path"); const [root, target, deny] = process.argv.slice(1);
const orig = fs.readdirSync; let calls = 0;
fs.readdirSync = function (p, ...rest) {
  calls += 1;
  if (deny === "deny") { const e = new Error("EACCES: permission denied (stub)"); e.code = "EACCES"; throw e; }
  return orig.call(this, p, ...rest);
};
const prf = require(path.join(root, "hooks/lib/path-real-fold.js"));
calls = 0;
let got = null, threw = null; try { got = prf.realResolve(target); } catch (e) { threw = String(e && e.code); }
process.stdout.write(JSON.stringify({ calls, got, threw }));`;

const NO_FOLD_SKIP = FOLDS ? `platform folds letter case (platform=${process.platform})` : false;
const FOLD_SKIP = FOLDS ? platformRuleMismatch() : `platform does not fold letter case (platform=${process.platform})`;
if (NO_FOLD_SKIP) process.stdout.write(`# skip no-fold readdir cases: ${NO_FOLD_SKIP}\n`);
if (FOLD_SKIP) process.stdout.write(`# skip fold readdir cases: ${FOLD_SKIP}\n`);

caseBegin("real-entry-name-skips-readdir-without-fold", "hooks/lib/path-real-fold.js");
test("real-entry-name-skips-readdir-without-fold", { skip: NO_FOLD_SKIP }, () => {
  prf("realResolve");
  const target = path.join(SB, "nofold", "Sub", "leaf");
  fs.mkdirSync(target, { recursive: true });
  const got = child(CHILD_READDIR_COUNT, [target, "deny"]);
  assert.equal(got.threw, null, "an existing path resolves although readdir would fail");
  assert.equal(got.calls, 0, "no readdir on a non-folding platform");
  assert.equal(got.got, fs.realpathSync.native(target), "the typed spelling is kept");
});
caseEnd();

caseBegin("real-entry-name-reads-dir-with-fold", "hooks/lib/path-real-fold.js");
test("real-entry-name-reads-dir-with-fold", { skip: FOLD_SKIP }, () => {
  prf("realResolve");
  const dir = path.join(SB, "fold-rd");
  fs.mkdirSync(path.join(dir, "Rd-Leaf"), { recursive: true });
  const got = child(CHILD_READDIR_COUNT, [path.join(dir, "rd-leaf"), "allow"]);
  assert.equal(got.threw, null, `resolves: ${got.threw}`);
  assert.ok(got.calls > 0, "readdir is consulted on a folding platform");
  assert.equal(path.basename(got.got), "Rd-Leaf", "the on-disk spelling replaces the typed one");
  const denied = child(CHILD_READDIR_COUNT, [path.join(dir, "rd-leaf"), "deny"]);
  assert.equal(denied.threw, "EACCES", "a readdir failure still fails the walk where case folds");
});
caseEnd();

caseBegin("readdir-without-a-matching-entry-throws", "hooks/lib/path-real-fold.js");
test("readdir-without-a-matching-entry-throws", { skip: FOLD_SKIP }, () => {
  prf("realResolve");
  const target = `${B}/my-task/main`;
  const noEntry = child(CHILD_NO_ENTRY, [target, MAIN, path.join(MAIN, ".claude")]);
  assert.ok(noEntry.threw, "a segment with no matching readdir entry throws");
  assert.equal(noEntry.inBase, false, "and the classifier refuses");
});
caseEnd();

// A real traversable-but-unlistable parent (POSIX 0311: owner wx, no r); the probe decides whether chmod denies listing.
const UNLISTABLE = path.join(SB, "unlistable");
let UNLISTABLE_SKIP = NO_FOLD_SKIP;
if (!UNLISTABLE_SKIP && typeof process.getuid === "function" && process.getuid() === 0) {
  UNLISTABLE_SKIP = "running as root, which lists a 0311 directory anyway";
}
if (!UNLISTABLE_SKIP) {
  fs.mkdirSync(path.join(UNLISTABLE, "inner"), { recursive: true });
  try {
    fs.chmodSync(UNLISTABLE, 0o311);
    fs.readdirSync(UNLISTABLE);
    UNLISTABLE_SKIP = "chmod 0311 does not deny listing on this file system";
  } catch (e) {
    if (e.code !== "EACCES") UNLISTABLE_SKIP = `chmod unsupported here (${e.code})`;
  } finally {
    fs.chmodSync(UNLISTABLE, 0o755);
  }
}
if (UNLISTABLE_SKIP) process.stdout.write(`# skip unlistable-parent case: ${UNLISTABLE_SKIP}\n`);

caseBegin("unlistable-parent-resolves-without-fold", "hooks/lib/path-real-fold.js");
test("unlistable-parent-resolves-without-fold", { skip: UNLISTABLE_SKIP }, () => {
  const realResolve = prf("realResolve");
  const target = path.join(UNLISTABLE, "inner");
  const expected = fs.realpathSync.native(target);
  fs.chmodSync(UNLISTABLE, 0o311);
  try {
    assert.throws(() => fs.readdirSync(UNLISTABLE), { code: "EACCES" }, "fixture: the parent cannot be listed");
    assert.equal(realResolve(target), expected, "resolved with the typed spelling, no throw");
  } finally {
    fs.chmodSync(UNLISTABLE, 0o755);
  }
});
caseEnd();
