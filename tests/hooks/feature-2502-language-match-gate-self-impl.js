"use strict";
// Tests: hooks/block-case-markers.js, hooks/lib/precommit-tests-frontmatter.sh
// Tags: TL2, hooks, edit-time, warn-context, scope:issue-specific, self-impl, fail-open, dup-group-keep:size-hard-limit
// #2502 S3-4: the edit-time hook runs bin/check-self-impl.sh on every NEW test file and blocks on a
// self-implemented harness. A WARN alone goes out as additionalContext, next to a HIGH it joins
// the block reason, and with none the notice stays empty. A missing CLI file skips that CLI only.
// CASE_MARKER_READER_UNSUPPORTED cannot reach the hook (a candidate needs a case reader); the CLI
// level pins it (tests/bin/feature-2411-gate-three-languages/gate-unsupported.sh).
// Split from feature-2502-language-match-gate.js for run time; fixtures in its sibling folder.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2502-lmg-si-"));
const NEUTRAL = path.join(ROOT, "cwd");
const DECOY = path.join(ROOT, "decoy");
fs.mkdirSync(NEUTRAL);
fs.mkdirSync(DECOY);
process.env.AGENTS_MAIN_ROOT = DECOY;
for (const k of ["CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "GIT_DIR", "GIT_WORK_TREE"]) delete process.env[k];
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const common = require("./feature-2502-language-match-gate/common");
const si = require("./feature-2502-language-match-gate/self-impl-helpers");
const { mkRepo } = common.make({ ROOT, NEUTRAL, gitInit });
const { mkSiRepo, mkCheckout, siHook } = si.make({ ROOT, NEUTRAL, mkRepo });
const { SI_CLI, resolves, SI_HEAD, BODY, writeInput, reasonOf, contextOf, show } = si;
const { expectBlock, expectApprove, expectNoTempPath, envWithout } = si;

caseBegin("self-impl-cli-present", "hooks/block-case-markers.js");
test("bin/check-self-impl.sh exists for the hook to call", () => {
  assert.ok(fs.existsSync(SI_CLI), `missing: ${SI_CLI}`);
});
caseEnd();

caseBegin("new-bash-self-impl-blocks", "hooks/block-case-markers.js");
test("a new bash test with a hand-made counter is blocked, reason names the rel path", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/x.sh", BODY.shBad));
  expectBlock(r, "code=SELF_IMPLEMENTED_HARNESS", "tests/bin/x.sh line 5", "tests/bin/x.sh line 6");
  expectNoTempPath(r);
});
caseEnd();

caseBegin("new-js-self-impl-blocks", "hooks/block-case-markers.js");
test("a new js test with a counter and a helper redefinition is blocked", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/hooks/x.js", BODY.jsBad));
  expectBlock(r, "code=SELF_IMPLEMENTED_HARNESS", "tests/hooks/x.js line 4", "tests/hooks/x.js line 5");
});
caseEnd();

caseBegin("new-pytest-self-impl-blocks", "hooks/block-case-markers.js");
test("a new pytest test with a counter is blocked", { skip: !resolves("uv") && "uv not installed" }, () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/test_x.py", BODY.pyBad));
  expectBlock(r, "code=SELF_IMPLEMENTED_HARNESS", "tests/bin/test_x.py line 5");
});
caseEnd();

caseBegin("new-pester-self-impl-blocks", "hooks/block-case-markers.js");
test("a new Pester test with a counter is blocked", { skip: !resolves("pwsh") && "pwsh not installed" }, () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/x.Tests.ps1", BODY.pesterBad));
  expectBlock(r, "code=SELF_IMPLEMENTED_HARNESS", "tests/bin/x.Tests.ps1 line 6");
});
caseEnd();

caseBegin("clean-new-file-empty-notice", "hooks/block-case-markers.js");
test("(c) a clean new file is approved and the notice stays empty", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/x.sh", BODY.shClean));
  expectApprove(r);
  assert.strictEqual(contextOf(r), "", show(r));
});
caseEnd();

caseBegin("existing-file-one-path-self-impl-checked", "hooks/block-case-markers.js");
// An existing file goes to check-self-impl --head with its HEAD copy: a counter new to HEAD blocks,
// one HEAD already has (existing debt) does not. A one-path Tests: exempts it from S4-4b.
test("an Edit adding a counter to an existing one-path file is blocked; HEAD's own counter is not", () => {
  const edit = (head, oldString, newString) => {
    const repo = mkRepo({ ...SI_HEAD, "tests/bin/old.sh": head });
    return siHook({ tool_name: "Edit", cwd: repo, tool_input: {
      file_path: path.join(repo, "tests", "bin", "old.sh"), old_string: oldString, new_string: newString } });
  };
  for (const n of ["PASS=0; echo done\n", "PASS=0\necho done\n"]) {
    expectBlock(edit(BODY.shClean, "echo done\n", n), "code=SELF_IMPLEMENTED_HARNESS", "tests/bin/old.sh");
  }
  const debt = edit(BODY.shClean.replace("echo done", "PASS=0\necho done"), "echo done\n", "echo finished\n");
  expectApprove(debt);
  assert.ok(!(reasonOf(debt) + contextOf(debt)).includes("SELF_IMPL"), show(debt));
});
caseEnd();

caseBegin("runtime-unavailable-warn-notice", "hooks/block-case-markers.js");
test("(a) a Pester self-impl without pwsh is approved with SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE in the notice", (t) => {
  const env = envWithout("pwsh");
  if (!env) { t.skip("pwsh still resolves after filtering PATH"); return; }
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/x.Tests.ps1", BODY.pesterBad), { env });
  expectApprove(r);
  assert.ok(contextOf(r).includes("code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"), show(r));
  assert.ok(contextOf(r).includes("tests/bin/x.Tests.ps1"), show(r));
  expectNoTempPath(r);
});
caseEnd();

// A checkout whose registry gives js no caseEmbedRules: check-self-impl answers WARN for js.
const NO_EMBED = mkCheckout("checkout-no-js-embed", (dir) => {
  const file = path.join(dir, "hooks", "lib", "test-language-registry.json");
  const table = JSON.parse(fs.readFileSync(file, "utf8"));
  for (const e of table.entries) if (e.id === "js") e.caseEmbedRules = null;
  fs.writeFileSync(file, JSON.stringify(table, null, 2) + "\n");
});
const NO_EMBED_HOOK = path.join(NO_EMBED, "hooks", "block-case-markers.js");

caseBegin("unsupported-warn-notice", "hooks/block-case-markers.js");
test("(a) a js self-impl with no js caseEmbedRules is approved with SELF_IMPL_CHECK_UNSUPPORTED in the notice", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/hooks/x.js", BODY.jsBad), { hook: NO_EMBED_HOOK });
  expectApprove(r);
  assert.ok(contextOf(r).includes("code=SELF_IMPL_CHECK_UNSUPPORTED"), show(r));
  assert.ok(contextOf(r).includes("tests/hooks/x.js"), show(r));
});
caseEnd();

caseBegin("high-and-warn-both-in-reason", "hooks/block-case-markers.js");
test("(b) a case-marker HIGH next to a self-impl WARN blocks with both in the reason", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/hooks/two.js", BODY.jsTwoPathsNoMarkers), { hook: NO_EMBED_HOOK });
  expectBlock(r, "code=MISSING_CASE_MARKERS", "code=SELF_IMPL_CHECK_UNSUPPORTED", "tests/hooks/two.js");
});
caseEnd();

// A checkout without bin/check-self-impl.sh: only that CLI is skipped.
const NO_SI = mkCheckout("checkout-no-self-impl", (dir) => {
  fs.rmSync(path.join(dir, "bin", "check-self-impl.sh"), { force: true });
});
const NO_SI_HOOK = path.join(NO_SI, "hooks", "block-case-markers.js");

caseBegin("missing-self-impl-cli-skips-it-only", "hooks/block-case-markers.js");
test("without bin/check-self-impl.sh a self-impl body passes and the case-marker check still blocks", () => {
  const ok = siHook(writeInput(mkSiRepo(), "tests/bin/x.sh", BODY.shBad), { hook: NO_SI_HOOK });
  expectApprove(ok);
  const bad = siHook(writeInput(mkSiRepo(), "tests/bin/two.sh", BODY.shTwoPathsNoMarkers), { hook: NO_SI_HOOK });
  expectBlock(bad, "code=MISSING_CASE_MARKERS", "tests/bin/two.sh");
});
caseEnd();
