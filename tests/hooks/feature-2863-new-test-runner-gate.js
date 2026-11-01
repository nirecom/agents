"use strict";
// Tests: hooks/block-case-markers.js, hooks/lib/test-gates/test-runner.js
// Tags: TL2, hooks, edit-time, test-runner, scope:issue-specific
// #2863 edit-time layer: a NEW JavaScript test entrypoint that does not load node:test is refused
// with MISSING_TEST_RUNNER and the registry hint; existing files, other languages, repos without
// the helper library and checkouts without the CLI are left alone.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2863-trg-"));
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
const F = require("./feature-2863-test-runner/fixtures");

const { mkRepo } = common.make({ ROOT, NEUTRAL, gitInit });
const { mkSiRepo, mkCheckout, siHook } = si.make({ ROOT, NEUTRAL, mkRepo });
const { writeInput, reasonOf, contextOf, show, expectBlock, expectApprove, expectNoTempPath } = si;
const REL = "tests/bin/x.js";
const writeNew = (body, repo = mkSiRepo(), rel = REL) => siHook(writeInput(repo, rel, body));
const noRunnerCode = (r) => assert.ok(!(reasonOf(r) + contextOf(r)).includes("TEST_RUNNER"), show(r));

caseBegin("e1-plain-script-blocked", "hooks/block-case-markers.js");
test("E1: a new plain script that requires only the harness is refused with the code, the HIGH line and the hint", () => {
  const r = writeNew(F.BODY.plain);
  expectBlock(r, `code=${F.CODE}`, REL, "(skip-reason custom-runner)", "require(\"node:test\")",
    "require(\"../lib/harness\")", "case-markers/js.md");
  const reason = reasonOf(r);
  assert.ok(reason.includes("[block-case-markers] Test file(s) fail the test gates:"), show(r));
  assert.ok(reason.includes(`  ${REL}: ${F.highLine(REL)}`), show(r));
  assert.ok(reason.split("\n").includes(F.HINT), `the hint is not its own line: ${show(r)}`);
  expectNoTempPath(r);
});
caseEnd();

caseBegin("e1-hint-from-runnerHint", "hooks/lib/test-gates/test-runner.js");
test("E1: the hook's hint line is the one runnerHint builds from the js registry entry", () => {
  const TR = require(path.join(common.CHECKOUT, "hooks", "lib", "test-gates", "test-runner.js"));
  const R = require(path.join(common.CHECKOUT, "hooks", "lib", "test-gates", "registry.js"));
  const m = R.match(REL);
  assert.ok(m && m.entry, "the js entry matches tests/bin/x.js");
  assert.strictEqual(TR.runnerHint(m.entry), F.HINT);
  const r = writeNew(F.BODY.plain);
  assert.strictEqual(reasonOf(r).split("\n").filter((l) => l === F.HINT).length, 1, show(r));
});
caseEnd();

caseBegin("e2-require-node-test", "hooks/block-case-markers.js");
test("E2: a new file that requires node:test is approved and carries no runner code", () => {
  const r = writeNew(F.BODY.nodeTest);
  expectApprove(r);
  noRunnerCode(r);
});
caseEnd();

caseBegin("e3-import-node-test", "hooks/block-case-markers.js");
test("E3: a new file that imports node:test (static or dynamic import) is approved", () => {
  for (const body of [F.BODY.importTest, F.BODY.dynamicImport]) {
    const r = writeNew(body);
    expectApprove(r);
    noRunnerCode(r);
  }
});
caseEnd();

caseBegin("e4-node-test-only-in-comment-or-string", "hooks/block-case-markers.js");
test("E4: node:test only inside a comment or a string literal does not count: each variant is refused", () => {
  const repo = mkSiRepo();
  for (const key of ["lineComment", "blockComment", "string", "template"]) {
    const r = writeNew(F.BODY[key], repo);
    expectBlock(r, `code=${F.CODE}`, REL);
    assert.ok(reasonOf(r).includes(F.HINT), `${key}: ${show(r)}`);
  }
});
caseEnd();

caseBegin("e5-existing-plain-script-edit", "hooks/block-case-markers.js");
test("E5: editing a plain script already in HEAD is not checked for the runner", () => {
  const repo = mkRepo({ ...si.SI_HEAD, [REL]: F.BODY.plain });
  const abs = path.join(repo, ...REL.split("/"));
  const r = siHook({ tool_name: "Edit", cwd: repo, tool_input: { file_path: abs, old_string: "isolate();", new_string: "isolate();\n// edited" } });
  expectApprove(r);
  noRunnerCode(r);
  const w = siHook(writeInput(repo, REL, F.BODY.plain + "// rewritten\n"));
  expectApprove(w);
  noRunnerCode(w);
});
caseEnd();

caseBegin("e6-bash-test-untouched", "hooks/block-case-markers.js");
test("E6: a new bash test is not checked for the runner (its entry declares no newEntrypointRunner)", () => {
  const repo = mkSiRepo();
  const r = siHook(writeInput(repo, "tests/bin/x.sh", si.BODY.shClean));
  expectApprove(r);
  noRunnerCode(r);
});
caseEnd();

caseBegin("e7-repo-without-helper-library", "hooks/block-case-markers.js");
test("E7: a repo without tests/lib/harness.js is not gated: the plain script is approved", () => {
  const repo = mkRepo(si.SI_HEAD, { noHelpers: true });
  const r = writeNew(F.BODY.plain, repo);
  expectApprove(r);
  noRunnerCode(r);
});
caseEnd();

caseBegin("e8-checkout-without-cli", "hooks/block-case-markers.js");
test("E8: a checkout without bin/check-test-runner.sh skips that CLI only; the case-marker CLI still blocks", () => {
  const co = mkCheckout("no-runner-cli", (dir) => {
    fs.rmSync(path.join(dir, "bin", "check-test-runner.sh"), { force: true });
  });
  const hook = path.join(co, "hooks", "block-case-markers.js");
  const plainRun = siHook(writeInput(mkSiRepo(), REL, F.BODY.plain), { hook });
  expectApprove(plainRun);
  assert.ok(!(reasonOf(plainRun) + contextOf(plainRun)).includes(F.CODE), show(plainRun));
  const twoRun = siHook(writeInput(mkSiRepo(), REL, F.BODY.twoPathsPlain), { hook });
  expectBlock(twoRun, "code=MISSING_CASE_MARKERS", REL);
  assert.ok(!reasonOf(twoRun).includes(F.CODE), show(twoRun));
});
caseEnd();

caseBegin("e9-two-highs-two-hints", "hooks/block-case-markers.js");
test("E9: a markerless two-target plain script gets both HIGH lines and both hints in one reason", () => {
  const r = writeNew(F.BODY.twoPathsPlain);
  expectBlock(r, "code=MISSING_CASE_MARKERS", `code=${F.CODE}`, "Wrap each case in column-0", F.HINT);
  const reason = reasonOf(r).split("\n");
  assert.strictEqual(reason.filter((l) => l === F.HINT).length, 1, show(r));
  assert.strictEqual(reason.filter((l) => l.startsWith("Wrap each case in column-0")).length, 1, show(r));
});
caseEnd();
