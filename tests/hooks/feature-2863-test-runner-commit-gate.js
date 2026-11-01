"use strict";
// Tests: hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js, hooks/pre-commit.d/checks/tests-frontmatter.js
// Tags: TL2, hooks, pre-commit, test-runner, scope:issue-specific
// #2863 commit-time layer: a NEW staged JavaScript test entrypoint without node:test blocks the
// tests-frontmatter check (renames count as new, a merge judges against both parents), an
// unreadable registry skips the gate with one line, and the gate runs after case-markers and
// before language-match.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2863-cg-"));
const NEUTRAL = path.join(ROOT, "cwd");
const DECOY = path.join(ROOT, "decoy");
fs.mkdirSync(NEUTRAL);
fs.mkdirSync(DECOY);
process.env.AGENTS_MAIN_ROOT = DECOY;
for (const k of ["CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "GIT_DIR", "GIT_WORK_TREE"]) delete process.env[k];
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort */ }
});

const common = require("./feature-2502-language-match-gate/common");
const si = require("./feature-2502-language-match-gate/self-impl-helpers");
const { makeTemplate, AGENTS_SEQUENCE, show: commitShow } = require("./feature-2507-precommit-node/commit-template");
const F = require("./feature-2863-test-runner/fixtures");

const { git, writeRel, CHECKOUT } = common;
const { mkRepo } = common.make({ ROOT, NEUTRAL, gitInit });
const RUNNER = path.join(CHECKOUT, "tests", "lib", "precommit-check-runner.js");

// check(repo, opts) — the shipped tests-frontmatter check (every gate, in order) over repo's index;
// opts.gate runs one gate alone, opts.cfg replaces the checkout. text is stdout + stderr.
function check(repo, { gate, cfg = CHECKOUT } = {}) {
  const args = [RUNNER, "--cfg", cfg, "tests-frontmatter", ...(gate ? [gate] : [])];
  const r = spawnSync(process.execPath, args, { cwd: repo, encoding: "utf8", env: process.env, timeout: 180000 });
  const text = `${r.stdout || ""}\n${r.stderr || ""}`;
  return { rc: r.status, stderr: r.stderr || "", text, show: `rc=${r.status} stdout=[${r.stdout}] stderr=[${r.stderr}]` };
}
const stage = (repo, files) => {
  for (const [rel, body] of Object.entries(files)) writeRel(repo, rel, body);
  git(repo, "add", "--", ...Object.keys(files));
};
const count = (text, needle) => text.split(needle).length - 1;

caseBegin("c1-real-commit-blocked", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C1: a real git commit of a new plain script is refused at tests-frontmatter with the hint", () => {
  const X = makeTemplate(path.join(ROOT, "commit"), gitInit);
  const dir = X.agents("runner");
  X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
  const rel = "tests/bin/x.js";
  X.write(dir, rel, F.plain("bin/check-case-markers/cli.js"));
  X.stage(dir, [rel]);
  const r = X.commit(dir);
  assert.notStrictEqual(r.status, 0, commitShow(r));
  assert.strictEqual(X.headCount(dir), 1, "no commit was made");
  for (const w of [F.highLine(rel), F.COMMIT_HEADLINE, F.HINT]) {
    assert.ok(r.stderr.includes(w), `missing ${JSON.stringify(w)}\n${commitShow(r)}`);
  }
  assert.deepStrictEqual(r.markers, AGENTS_SEQUENCE.slice(0, AGENTS_SEQUENCE.indexOf("tests-frontmatter") + 1));
});
caseEnd();

caseBegin("c1-hint-once-per-entry", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C1: two new plain scripts are both named, under one headline and one hint", () => {
  const repo = mkRepo(si.SI_HEAD);
  stage(repo, { "tests/bin/x.js": F.BODY.plain, "tests/bin/y.js": F.BODY.plain });
  const r = check(repo);
  assert.strictEqual(r.rc, 1, r.show);
  assert.ok(r.text.includes(F.highLine("tests/bin/x.js")) && r.text.includes(F.highLine("tests/bin/y.js")), r.show);
  assert.strictEqual(count(r.text, F.COMMIT_HEADLINE), 1, r.show);
  assert.strictEqual(count(r.text, F.HINT), 1, r.show);
});
caseEnd();

caseBegin("c2-node-test-passes", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C2: new files that load node:test (require or import) pass", () => {
  const repo = mkRepo(si.SI_HEAD);
  stage(repo, { "tests/bin/x.js": F.BODY.nodeTest, "tests/bin/y.js": F.BODY.importTest });
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes("TEST_RUNNER"), r.show);
  assert.strictEqual(check(repo, { gate: "test-runner" }).rc, 0);
});
caseEnd();

caseBegin("c3-existing-file-modified", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C3 (#2865): a modified plain script already in HEAD is refused", () => {
  const rel = "tests/bin/x.js";
  const repo = mkRepo({ ...si.SI_HEAD, [rel]: F.BODY.plain });
  stage(repo, { [rel]: F.BODY.plain + "// modified\n" });
  const r = check(repo);
  assert.strictEqual(r.rc, 1, r.show);
  assert.ok(r.text.includes(F.CODE), r.show);
  assert.ok(r.text.includes(F.highLine(rel)), r.show);
  assert.ok(r.text.includes(F.COMMIT_HEADLINE), r.show);
  assert.ok(r.text.includes(F.HINT), r.show);
});
caseEnd();

caseBegin("c4-rename-is-new", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C4: git mv of an existing plain script is a new file and is refused under the new path", () => {
  const repo = mkRepo({ ...si.SI_HEAD, "tests/bin/old.js": F.BODY.plain });
  git(repo, "mv", "tests/bin/old.js", "tests/bin/new.js");
  const r = check(repo);
  assert.strictEqual(r.rc, 1, r.show);
  assert.ok(r.text.includes(F.highLine("tests/bin/new.js")), r.show);
  assert.ok(!r.text.includes("tests/bin/old.js"), r.show);
});
caseEnd();

caseBegin("c5-merge-judged-by-parents", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C5 (#2865): a merge taking a plain script from MERGE_HEAD is refused, and so is a file new to both parents", () => {
  const repo = mkRepo(si.SI_HEAD);
  const main = git(repo, "rev-parse", "--abbrev-ref", "HEAD").trim();
  git(repo, "checkout", "-q", "-b", "side");
  stage(repo, { "tests/bin/side.js": F.BODY.plain });
  git(repo, "commit", "-q", "-m", "side");
  git(repo, "checkout", "-q", main);
  stage(repo, { "notes.txt": "main\n" });
  git(repo, "commit", "-q", "-m", "main");
  git(repo, "merge", "--no-ff", "--no-commit", "side");
  const r = check(repo);
  assert.strictEqual(r.rc, 1, r.show);
  assert.ok(r.text.includes(F.highLine("tests/bin/side.js")), r.show);
  stage(repo, { "tests/bin/both.js": F.BODY.plain });
  const b = check(repo);
  assert.strictEqual(b.rc, 1, b.show);
  assert.ok(b.text.includes(F.highLine("tests/bin/both.js")), b.show);
  assert.ok(b.text.includes(F.highLine("tests/bin/side.js")), b.show);
});
caseEnd();

caseBegin("c4-rename-of-node-test-passes", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C4 (#2865): git mv of an existing node:test entrypoint passes (the moved file still loads node:test)", () => {
  const repo = mkRepo({ ...si.SI_HEAD, "tests/bin/old.js": F.BODY.nodeTest });
  git(repo, "mv", "tests/bin/old.js", "tests/bin/new.js");
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes("TEST_RUNNER"), r.show);
});
caseEnd();

caseBegin("c5-merge-takes-node-test-passes", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C5 (#2865): a merge taking a node:test entrypoint from MERGE_HEAD passes", () => {
  const repo = mkRepo(si.SI_HEAD);
  const main = git(repo, "rev-parse", "--abbrev-ref", "HEAD").trim();
  git(repo, "checkout", "-q", "-b", "side");
  stage(repo, { "tests/bin/side.js": F.BODY.nodeTest });
  git(repo, "commit", "-q", "-m", "side");
  git(repo, "checkout", "-q", main);
  stage(repo, { "notes.txt": "main\n" });
  git(repo, "commit", "-q", "-m", "main");
  git(repo, "merge", "--no-ff", "--no-commit", "side");
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes("TEST_RUNNER"), r.show);
});
caseEnd();

caseBegin("g2-untouched-legacy-plain-script-passes", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("G2 (#2865): a plain placed script in HEAD that the change does not touch never blocks a change to another file", () => {
  const legacy = "tests/bin/legacy.js";
  const other = "tests/bin/other.js";
  const repo = mkRepo({ ...si.SI_HEAD, [legacy]: F.BODY.plain, [other]: F.BODY.nodeTest });
  stage(repo, { [other]: F.BODY.nodeTest + "// modified\n" });
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes("TEST_RUNNER") && !r.text.includes(legacy), r.show);
  const g = check(repo, { gate: "test-runner" });
  assert.strictEqual(g.rc, 0, g.show);
  assert.ok(!g.text.includes(legacy), g.show);
  stage(repo, { "notes.txt": "source change\n" });
  const s = check(repo);
  assert.strictEqual(s.rc, 0, s.show);
  assert.ok(!s.text.includes(legacy), s.show);
});
caseEnd();

caseBegin("g2-existing-node-test-modified-passes", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("G2 (#2865): a modified file already in HEAD that requires node:test passes (no over-blocking)", () => {
  const rel = "tests/bin/x.js";
  const repo = mkRepo({ ...si.SI_HEAD, [rel]: F.BODY.nodeTest });
  stage(repo, { [rel]: F.BODY.nodeTest + "// modified\n" });
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes("TEST_RUNNER"), r.show);
  assert.strictEqual(check(repo, { gate: "test-runner" }).rc, 0);
});
caseEnd();

caseBegin("g2-repo-without-helper-library-passes", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("G2 (#2865): a repo without the helper library passes even with a modified and a new plain script staged", () => {
  const rel = "tests/bin/x.js";
  const repo = mkRepo({ ...si.SI_HEAD, [rel]: F.BODY.plain }, { noHelpers: true });
  stage(repo, { [rel]: F.BODY.plain + "// modified\n", "tests/bin/y.js": F.BODY.plain });
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes(F.CODE), r.show);
});
caseEnd();

caseBegin("g2-head-plain-staged-node-test-passes","hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("G2 (#2865): HEAD is a plain script and the staged change makes it a node:test file: the staged content is judged and passes", () => {
  const rel = "tests/bin/x.js";
  const repo = mkRepo({ ...si.SI_HEAD, [rel]: F.BODY.plain });
  stage(repo, { [rel]: F.BODY.nodeTest });
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes("TEST_RUNNER"), r.show);
});
caseEnd();

caseBegin("g2-head-node-test-staged-plain-blocked", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("G2 (#2865): HEAD requires node:test and the staged change drops it: the commit is refused", () => {
  const rel = "tests/bin/x.js";
  const repo = mkRepo({ ...si.SI_HEAD, [rel]: F.BODY.nodeTest });
  stage(repo, { [rel]: F.BODY.plain });
  const r = check(repo);
  assert.strictEqual(r.rc, 1, r.show);
  assert.ok(r.text.includes(F.highLine(rel)), r.show);
  assert.ok(r.text.includes(F.COMMIT_HEADLINE), r.show);
  assert.ok(r.text.includes(F.HINT), r.show);
});
caseEnd();

caseBegin("g2-non-placed-existing-plain-passes", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("G2 (#2865): modified plain scripts in HEAD under tests/lib/ and a sibling module folder are not placed, so they pass", () => {
  const files = ["tests/lib/x.js", "tests/bin/sib/helper.js"];
  const repo = mkRepo({ ...si.SI_HEAD, "tests/bin/sib.js": F.BODY.nodeTest, [files[0]]: F.BODY.plain, [files[1]]: F.BODY.plain });
  stage(repo, { [files[0]]: F.BODY.plain + "// modified\n", [files[1]]: F.BODY.plain + "// modified\n" });
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes("TEST_RUNNER"), r.show);
  assert.strictEqual(check(repo, { gate: "test-runner" }).rc, 0);
});
caseEnd();

caseBegin("g2-existing-bash-test-modified-no-runner-finding", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("G2 (#2865): a modified bash test already in HEAD gets no TEST_RUNNER finding", () => {
  const rel = "tests/bin/x.sh";
  const repo = mkRepo({ ...si.SI_HEAD, [rel]: si.BODY.shClean });
  stage(repo, { [rel]: si.BODY.shClean + "echo extra\n" });
  const r = check(repo);
  assert.ok(!r.text.includes("TEST_RUNNER"), r.show);
  const g = check(repo, { gate: "test-runner" });
  assert.strictEqual(g.rc, 0, g.show);
  assert.ok(!g.text.includes("TEST_RUNNER"), g.show);
});
caseEnd();

caseBegin("g2-deleting-plain-script-passes", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("G2 (#2865): deleting a plain script that is in HEAD passes (nothing is left to judge)", () => {
  const rel = "tests/bin/x.js";
  const repo = mkRepo({ ...si.SI_HEAD, [rel]: F.BODY.plain });
  git(repo, "rm", "-q", "--", rel);
  const r = check(repo);
  assert.strictEqual(r.rc, 0, r.show);
  assert.ok(!r.text.includes("TEST_RUNNER"), r.show);
});
caseEnd();

caseBegin("c6-unreadable-registry", "hooks/pre-commit.d/checks/tests-frontmatter/test-runner-gate.js");
test("C6: an unreadable registry skips the gate with one stderr line and the commit continues", () => {
  const cfg = path.join(ROOT, "cfg-corrupt");
  for (const sub of ["bin", "hooks"]) fs.cpSync(path.join(CHECKOUT, sub), path.join(cfg, sub), { recursive: true });
  fs.writeFileSync(path.join(cfg, "hooks", "lib", "test-language-registry.json"), "{ not json\n");
  const repo = mkRepo(si.SI_HEAD);
  stage(repo, { "tests/bin/x.js": F.BODY.plain });
  const r = check(repo, { gate: "test-runner", cfg });
  assert.strictEqual(r.rc, 0, r.show);
  assert.deepStrictEqual(r.stderr.split(/\r?\n/).filter((l) => l.includes("test-runner check skipped")), [F.SKIP_LINE], r.show);
  assert.ok(!r.text.includes(F.CODE), r.show);
});
caseEnd();

caseBegin("c7-gate-order", "hooks/pre-commit.d/checks/tests-frontmatter.js");
test("C7: the runner gate runs after case-markers and before language-match, first block ends the check", () => {
  const markerless = mkRepo(si.SI_HEAD);
  stage(markerless, { "tests/bin/x.js": F.BODY.twoPathsPlain });
  const m = check(markerless);
  assert.strictEqual(m.rc, 1, m.show);
  assert.ok(m.text.includes("code=MISSING_CASE_MARKERS") && !m.text.includes(F.CODE), m.show);

  const mismatch = mkRepo(si.SI_HEAD);
  stage(mismatch, { "tests/bin/x.js": F.plain("bin/a.sh") });
  const lm = check(mismatch, { gate: "language-match" });
  assert.ok(lm.rc === 1 && lm.text.includes("code=TEST_LANGUAGE_MISMATCH"), `the fixture is a mismatch: ${lm.show}`);
  const l = check(mismatch);
  assert.strictEqual(l.rc, 1, l.show);
  assert.ok(l.text.includes(F.highLine("tests/bin/x.js")), l.show);
  assert.ok(!l.text.includes("TEST_LANGUAGE_MISMATCH"), l.show);
  const alone = check(markerless, { gate: "test-runner" });
  assert.ok(alone.rc === 1 && alone.text.includes(F.highLine("tests/bin/x.js")), `the gate alone still sees it: ${alone.show}`);
});
caseEnd();
