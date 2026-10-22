"use strict";
// Tests: bin/run-eslint, bin/run-eslint.d/main.js, bin/run-eslint.d/provision.js, bin/run-eslint.d/lint.js, bin/run-eslint.d/locate-config.js, package.json, package-lock.json
// Tags: TL2, bin, eslint, lint, run-eslint, wrapper, provision, npm-ci, lockfile-stamp, exit-codes, same-repository, fake-package, scope:issue-specific, linked-worktree, auto-provision
// #2739: the contract of `node bin/run-eslint <path>...` against a fake eslint package and npm
// stubs (RUN_ESLINT_NPM_CLI) built under a temp root by ./feature-2739-run-eslint/fixtures.js.
// Assumed interface: bin/run-eslint.d/provision.js exports isSameRepository(lintRoot,
// wrapperRoot) (boolean, or a promise of one); the provision lock dir is
// os.tmpdir()/run-eslint-<sha1(lintRoot)>.lock and the stamp is node_modules/.run-eslint-lock.sha256.
// TL3 gap: a real `npm ci` and the real ESLint 10 API are not exercised here; Step 12 of the plan
// runs the wrapper over hooks/bin/tests with the real package.
const { caseBegin, caseEnd } = require("../lib/harness");
const fx = require("./feature-2739-run-eslint/fixtures");

const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const NOT_APPLICABLE = "eslint not applicable — check skipped";
const LIMITED = "auto-install is limited to the agents repository";
const ops = (p, op) => fx.readJsonl(p.log).filter((e) => e.op === op);
const npmCalls = (p) => fx.readJsonl(p.marker);
const show = (r) => `exit=${r.status}\nstdout:\n${r.stdout}\nstderr:\n${r.stderr}${r.error ? `\nerror: ${r.error.message}` : ""}`;
const sameDir = (a, b) => path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase();

caseBegin("dispatcher-keeps-the-checkout-root-form", "bin/run-eslint");
test("bin/run-eslint is a node-shebang dispatcher deriving SCRIPT_CHECKOUT_ROOT from __dirname", () => {
  const src = fs.readFileSync(path.join(fx.REPO, "bin", "run-eslint"), "utf8");
  assert.match(src.split(/\r?\n/)[0], /^#!.*\bnode\b/);
  assert.ok(src.includes('path.resolve(__dirname, "..")'), "SCRIPT_CHECKOUT_ROOT canonical form");
});
caseEnd();

caseBegin("usage-errors-exit-2", "bin/run-eslint.d/main.js");
test("no arguments -> usage on stderr, exit 2", () => {
  const r = fx.run(null, []);
  assert.strictEqual(r.status, 2, show(r));
  assert.ok(r.stderr.trim().length > 0, "usage text on stderr");
});
test("a path that does not exist -> exit 2", () => {
  const p = fx.project("missing-path", { eslint: true });
  const r = fx.run(p, [path.join(p.dir, "src", "no-such-file.js")]);
  assert.strictEqual(r.status, 2, show(r));
  assert.strictEqual(ops(p, "lintFiles").length, 0, "nothing is linted");
});
caseEnd();

caseBegin("no-config-above-the-file-skips", "bin/run-eslint.d/locate-config.js");
test("a file with no eslint.config.* above it -> exit 0 with the no-config skip notice", () => {
  const p = fx.project("no-config", { config: false, eslint: true });
  const r = fx.run(p, [p.file]);
  assert.strictEqual(r.status, 0, show(r));
  assert.ok(r.stdout.includes("check skipped (no eslint.config.*"), show(r));
});
test("one skipped path and one path with an error -> both reported, exit 1", () => {
  const bare = fx.project("mixed-bare", { config: false });
  const p = fx.project("mixed-linted", { eslint: true });
  const r = fx.run(p, [bare.file, p.file], { FAKE_ESLINT_ERRORS: "1" });
  assert.strictEqual(r.status, 1, show(r));
  assert.ok(r.stdout.includes("check skipped (no eslint.config.*"), show(r));
  assert.ok(r.stdout.includes("FAKE-FORMAT stylish"), show(r));
});
caseEnd();

caseBegin("no-lockfile-skips-without-npm", "bin/run-eslint.d/provision.js");
test("config, no lockfile, no eslint, RUN_ESLINT_PROVISION=1 -> skip (no package-lock.json), npm not run", () => {
  const p = fx.project("no-lock", {});
  const r = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1" });
  assert.strictEqual(r.status, 0, show(r));
  assert.ok(r.stdout.includes("eslint not found — check skipped"), show(r));
  assert.ok(r.stdout.includes("no package-lock.json"), show(r));
  assert.deepStrictEqual(npmCalls(p), []);
});
caseEnd();

caseBegin("npm-ci-failure-skips", "bin/run-eslint.d/provision.js");
test("npm ci exits 1 -> skip naming npm ci and the stderr tail, exit 0, no stamp, no lint", () => {
  const p = fx.project("npm-fail", { lock: true });
  const r = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1", RUN_ESLINT_NPM_CLI: fx.NPM_FAIL });
  assert.strictEqual(r.status, 0, show(r));
  assert.ok(r.stdout.includes("eslint not found — check skipped"), show(r));
  assert.ok(r.stdout.includes("npm ci"), show(r));
  assert.ok(r.stdout.includes("simulated npm failure"), show(r));
  assert.strictEqual(npmCalls(p).length, 1, "the failing stub was invoked once");
  assert.ok(!fs.existsSync(p.stamp), "no stamp after a failed npm ci");
  assert.strictEqual(ops(p, "lintFiles").length, 0);
  assert.deepStrictEqual(fx.lockDirs(), [], "the provision lock is released");
});
caseEnd();

caseBegin("npm-ci-success-provisions-and-stamps", "bin/run-eslint.d/provision.js");
test("no node_modules, RUN_ESLINT_PROVISION=1 -> npm ci runs in the lint root, lint runs, stamp = lockfile sha256", () => {
  const p = fx.project("npm-ok", { lock: true });
  const r = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1" });
  assert.strictEqual(r.status, 0, show(r));
  const calls = npmCalls(p);
  assert.strictEqual(calls.length, 1, show(r));
  assert.ok(sameDir(calls[0].cwd, p.dir), `npm ran in ${calls[0].cwd}`);
  for (const flag of ["ci", "--no-audit", "--no-fund", "--ignore-scripts"]) assert.ok(calls[0].argv.includes(flag), `npm argv has ${flag}: ${calls[0].argv}`);
  assert.strictEqual(ops(p, "lintFiles").length, 1, "lint ran after provisioning");
  assert.ok(r.stdout.includes("FAKE-FORMAT stylish"), show(r));
  assert.ok(fs.existsSync(p.stamp), "stamp written");
  assert.strictEqual(fs.readFileSync(p.stamp, "utf8").trim(), fx.sha256(p.lock));
  assert.deepStrictEqual(fx.lockDirs(), [], "the provision lock is released");
});
caseEnd();

caseBegin("stamp-decides-whether-npm-ci-reruns", "bin/run-eslint.d/provision.js");
test("matching stamp -> no npm ci; a one-byte transitive change -> npm ci again with a new stamp", () => {
  const p = fx.project("stamp", { lock: true });
  const first = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1" });
  assert.strictEqual(npmCalls(p).length, 1, `priming run provisions\n${show(first)}`);
  fs.rmSync(p.marker);

  const again = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1" });
  assert.strictEqual(again.status, 0, show(again));
  assert.deepStrictEqual(npmCalls(p), [], "stamp matches: npm ci is not re-run");
  assert.strictEqual(ops(p, "lintFiles").length, 2, "lint ran on both runs");

  const before = fx.sha256(p.lock);
  fx.bumpTransitive(p);
  assert.notStrictEqual(fx.sha256(p.lock), before, "premise: the lockfile changed");
  const changed = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1" });
  assert.strictEqual(changed.status, 0, show(changed));
  assert.strictEqual(npmCalls(p).length, 1, "a transitive-only lockfile change re-runs npm ci");
  assert.strictEqual(fs.readFileSync(p.stamp, "utf8").trim(), fx.sha256(p.lock));
});
test("eslint installed but no stamp (manual npm ci) -> npm ci runs once, then not again", () => {
  const p = fx.project("no-stamp", { lock: true, eslint: true });
  fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1" });
  assert.strictEqual(npmCalls(p).length, 1, "first run re-provisions to write the stamp");
  fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1" });
  assert.strictEqual(npmCalls(p).length, 1, "second run trusts the stamp");
});
test("a stale lock dir (older than 600 s) is removed and provisioning proceeds", () => {
  const p = fx.project("stale-lock", { lock: true });
  const forms = new Set([path.resolve(p.dir), fs.realpathSync.native(p.dir)]);
  const names = [...forms].map((d) => `run-eslint-${crypto.createHash("sha1").update(d).digest("hex")}.lock`);
  const old = new Date(Date.now() - 700 * 1000);
  for (const n of names) {
    fs.mkdirSync(path.join(fx.SYS_TMP, n), { recursive: true });
    fs.utimesSync(path.join(fx.SYS_TMP, n), old, old);
  }
  const r = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: "1" });
  assert.strictEqual(r.status, 0, show(r));
  assert.strictEqual(npmCalls(p).length, 1, show(r));
  assert.ok(names.some((n) => !fs.existsSync(path.join(fx.SYS_TMP, n))), "the stale lock for this lint root is gone");
  for (const n of names) fs.rmSync(path.join(fx.SYS_TMP, n), { recursive: true, force: true });
});
caseEnd();

caseBegin("auto-install-limited-to-the-agents-repository", "bin/run-eslint.d/provision.js");
test("another git repo, no opt-in, no node_modules -> npm not run, exit 0, limited-install notice", () => {
  const p = fx.project("other-repo", { lock: true, git: true });
  const r = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: null });
  assert.strictEqual(r.status, 0, show(r));
  assert.deepStrictEqual(npmCalls(p), [], "npm ci never runs in a foreign repository");
  assert.ok(r.stdout.includes(LIMITED), show(r));
  assert.ok(r.stdout.includes("RUN_ESLINT_PROVISION=1"), show(r));
});
test("another git repo with eslint already installed -> used read-only, npm not run", () => {
  const p = fx.project("other-repo-installed", { lock: true, git: true, eslint: true });
  const r = fx.run(p, [p.file], { RUN_ESLINT_PROVISION: null });
  assert.strictEqual(r.status, 0, show(r));
  assert.deepStrictEqual(npmCalls(p), []);
  assert.strictEqual(ops(p, "lintFiles").length, 1, show(r));
});
caseEnd();

caseBegin("same-repository-check", "bin/run-eslint.d/provision.js");
test("main checkout and its linked worktree are the same repository; another repo and a subdir are not", async () => {
  const main = fx.project("repo-main", { git: true }).dir;
  fx.git(main, "add", "-A");
  fx.git(main, "commit", "-q", "-m", "init");
  const wt = path.join(path.dirname(main), "repo-main-wt");
  fx.git(main, "worktree", "add", "-q", wt);
  assert.ok(fs.existsSync(path.join(wt, "eslint.config.js")), "premise: the linked worktree is checked out");
  const other = fx.project("repo-other", { git: true }).dir;
  const sub = path.join(main, "src");
  const plain = fx.project("not-a-repo", {}).dir;
  const { isSameRepository } = require(path.join(fx.REPO, "bin", "run-eslint.d", "provision.js"));
  assert.strictEqual(typeof isSameRepository, "function", "provision.js exports isSameRepository");

  assert.strictEqual(await isSameRepository(main, main), true, "main checkout vs itself");
  assert.strictEqual(await isSameRepository(wt, main), true, "linked worktree vs main checkout");
  assert.strictEqual(await isSameRepository(main, wt), true, "main checkout vs linked worktree");
  assert.strictEqual(await isSameRepository(other, main), false, "another repository");
  assert.strictEqual(await isSameRepository(sub, main), false, "a subdirectory is not a worktree top-level");
  assert.strictEqual(await isSameRepository(plain, main), false, "a directory outside any repository");
});
caseEnd();

// The default path: no RUN_ESLINT_PROVISION, a copy of the wrapper in its own fixture repo.
const autoProvisioned = (c, r) => {
  assert.strictEqual(r.status, 0, show(r));
  const calls = npmCalls(c);
  assert.strictEqual(calls.length, 1, `npm ci ran once\n${show(r)}`);
  assert.ok(sameDir(calls[0].cwd, c.dir), `npm ran in ${calls[0].cwd}, want ${c.dir}`);
  assert.ok(calls[0].argv.includes("ci"), `npm argv ${calls[0].argv}`);
  assert.strictEqual(ops(c, "lintFiles").length, 1, "lint ran after provisioning");
  assert.ok(!r.stdout.includes(LIMITED), show(r));
  assert.strictEqual(fs.readFileSync(c.stamp, "utf8").trim(), fx.sha256(c.lock), "stamp = lockfile sha256");
  assert.deepStrictEqual(fx.lockDirs(), [], "the provision lock is released");
};

caseBegin("linked-worktree-auto-provision", "bin/run-eslint.d/provision.js");
test("main checkout's wrapper on its linked worktree, provision unset -> npm ci in the worktree, lint, stamp", () => {
  const { main, wt } = fx.wrapperRepo("wt-auto");
  assert.ok(!fs.existsSync(path.join(wt.dir, "node_modules")), "premise: no node_modules");
  const c = { ...wt, wrapper: main.wrapper };
  autoProvisioned(c, fx.run(c, [c.file], { RUN_ESLINT_PROVISION: null }));

  const again = fx.run(c, [c.file], { RUN_ESLINT_PROVISION: null });
  assert.strictEqual(again.status, 0, show(again));
  assert.strictEqual(npmCalls(c).length, 1, "second run: stamp matches, npm ci not re-run");
  assert.strictEqual(ops(c, "lintFiles").length, 2, "lint ran on both runs");
});
test("the linked worktree's own wrapper copy, provision unset -> npm ci in the worktree", () => {
  const { wt } = fx.wrapperRepo("wt-own");
  autoProvisioned(wt, fx.run(wt, [wt.file], { RUN_ESLINT_PROVISION: null }));
});
test("main checkout of the same repo, provision unset -> npm ci in the main checkout", () => {
  const { main } = fx.wrapperRepo("main-auto");
  autoProvisioned(main, fx.run(main, [main.file], { RUN_ESLINT_PROVISION: null }));
});
caseEnd();

caseBegin("shell-metacharacter-path-is-one-pattern", "bin/run-eslint.d/main.js");
test("a path with spaces, & and $ reaches lintFiles as one literal pattern", () => {
  const p = fx.project("sp ace & $HOME x", { eslint: true });
  const r = fx.run(p, [p.file]);
  assert.strictEqual(r.status, 0, show(r));
  const calls = ops(p, "lintFiles");
  assert.strictEqual(calls.length, 1, show(r));
  assert.strictEqual(calls[0].patterns.length, 1, `patterns ${calls[0].patterns}`);
  assert.ok(sameDir(calls[0].patterns[0], p.file), `pattern ${calls[0].patterns[0]}`);
});
caseEnd();

caseBegin("exit-code-follows-error-count", "bin/run-eslint.d/lint.js");
test("errorCount 1 -> exit 1", () => {
  const p = fx.project("errors", { eslint: true });
  const r = fx.run(p, [p.file], { FAKE_ESLINT_ERRORS: "1" });
  assert.strictEqual(r.status, 1, show(r));
  assert.ok(r.stdout.includes("FAKE-FORMAT stylish errors=1"), show(r));
});
test("warnings only -> exit 0", () => {
  const p = fx.project("warnings", { eslint: true });
  const r = fx.run(p, [p.file], { FAKE_ESLINT_WARNINGS: "3" });
  assert.strictEqual(r.status, 0, show(r));
  assert.ok(r.stdout.includes("FAKE-FORMAT stylish errors=0"), show(r));
});
test("the lint root and the found config are handed to the ESLint API", () => {
  const p = fx.project("api-options", { eslint: true });
  fx.run(p, [p.file]);
  const made = ops(p, "new");
  assert.strictEqual(made.length, 1);
  assert.ok(sameDir(made[0].cwd, p.dir), `cwd ${made[0].cwd}`);
  assert.ok(sameDir(made[0].overrideConfigFile, path.join(p.dir, "eslint.config.js")), `config ${made[0].overrideConfigFile}`);
});
test("a directory argument goes to lintFiles as is", () => {
  const p = fx.project("dir-arg", { eslint: true });
  const r = fx.run(p, [path.join(p.dir, "src")], { FAKE_ESLINT_ACTIVE_RULES: "0" });
  assert.strictEqual(r.status, 0, show(r));
  const calls = ops(p, "lintFiles");
  assert.strictEqual(calls.length, 1, show(r));
  assert.ok(calls[0].patterns.some((q) => sameDir(q, path.join(p.dir, "src"))), `patterns ${calls[0].patterns}`);
});
test("an ESLint API exception -> message on stderr, exit 2", () => {
  const p = fx.project("api-throws", { eslint: true });
  const r = fx.run(p, [p.file], { FAKE_ESLINT_THROW: "1" });
  assert.strictEqual(r.status, 2, show(r));
  assert.ok(r.stderr.includes("fake eslint: config load failed"), show(r));
});
caseEnd();

caseBegin("uncovered-files-are-reported-not-linted", "bin/run-eslint.d/lint.js");
for (const [why, env] of [
  ["no active rule (default **/*.js block only)", { FAKE_ESLINT_ACTIVE_RULES: "0" }],
  ["isPathIgnored is true", { FAKE_ESLINT_IGNORED: "1" }],
  ["calculateConfigForFile is undefined", { FAKE_ESLINT_NO_CONFIG: "1" }],
]) {
  test(`${why} -> exit 0 with the not-applicable notice, no lint`, () => {
    const p = fx.project("uncovered", { eslint: true });
    const r = fx.run(p, [p.file], { ...env, FAKE_ESLINT_ERRORS: "1" });
    assert.strictEqual(r.status, 0, show(r));
    assert.ok(r.stdout.includes(NOT_APPLICABLE), show(r));
    assert.ok(r.stdout.includes("not covered by"), show(r));
    assert.strictEqual(ops(p, "lintFiles").length, 0, "an uncovered file is not linted");
  });
}
caseEnd();

caseBegin("windows-path-forms-resolve-alike", "bin/run-eslint.d/main.js");
test("backslash absolute path and /c/... form lint against the same lint root", (t) => {
  if (process.platform !== "win32") {
    t.skip("win32-only: drive-letter and /c/... path forms exist only on Windows");
    return;
  }
  const p = fx.project("win-paths", { eslint: true });
  const backslash = path.resolve(p.file);
  const posix = `/${backslash[0].toLowerCase()}${backslash.slice(2).replace(/\\/g, "/")}`;
  for (const arg of [backslash, posix]) {
    const r = fx.run(p, [arg]);
    assert.strictEqual(r.status, 0, `${arg}\n${show(r)}`);
  }
  const made = ops(p, "new");
  assert.strictEqual(made.length, 2, "one ESLint instance per run");
  for (const m of made) assert.ok(sameDir(m.cwd, p.dir), `cwd ${m.cwd}`);
  assert.strictEqual(ops(p, "lintFiles").length, 2, "both forms were linted");
});
caseEnd();

const readRepoJson = (name) => JSON.parse(fs.readFileSync(path.join(fx.REPO, name), "utf8"));
const PINNED = ["eslint", "@eslint/js", "globals"];

caseBegin("package-json-shape", "package.json");
test("package.json is private, has no type, and pins the three devDependencies exactly", () => {
  const pkg = readRepoJson("package.json");
  assert.strictEqual(pkg.private, true);
  assert.ok(!Object.prototype.hasOwnProperty.call(pkg, "type"), "no \"type\" field (CommonJS default)");
  assert.deepStrictEqual(Object.keys(pkg.devDependencies || {}).sort(), [...PINNED].sort());
  for (const name of PINNED) assert.match(pkg.devDependencies[name], /^\d+\.\d+\.\d+$/, `${name} is an exact pin`);
});
caseEnd();

caseBegin("lockfile-root-matches-package-json", "package-lock.json");
test("package-lock.json packages[\"\"].devDependencies equal package.json's exact pins", () => {
  const pkg = readRepoJson("package.json");
  const lock = readRepoJson("package-lock.json");
  const root = (lock.packages || {})[""] || {};
  assert.deepStrictEqual(root.devDependencies, pkg.devDependencies);
  for (const name of PINNED) {
    assert.ok(!/[\^~]/.test(root.devDependencies[name]), `${name} has no range operator`);
    assert.strictEqual(lock.packages[`node_modules/${name}`].version, pkg.devDependencies[name], `${name} resolved to the pinned version`);
  }
});
caseEnd();
