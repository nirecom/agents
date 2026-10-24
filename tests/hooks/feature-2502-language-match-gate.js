"use strict";
// Tests: hooks/block-case-markers.js, hooks/lib/precommit-tests-frontmatter.sh
// Tags: TL2, hooks, pre-commit, test-language-match, test-lang-exception:symmetry, edit-time, warn-context, scope:issue-specific, self-impl, fail-open
// #2502 S4-7: bin/check-test-language-match.sh is called from the edit-time hook and from the
// pre-commit gate _precommit_check_test_language_match; each row runs through both and must get
// the same verdict. New and existing files are both judged (existing ones with the HEAD copy).
// Judgment table: tests/bin/feature-2502-test-language-match.sh. Split siblings: -self-impl.js, -existing.js.
// TL3 gap: the hook as registered in a live session and the installed pre-commit hook
// (mitigation: tests/hooks/feature-1834-precommit-lib-split.sh part F pins the hook-line wiring).
// Host-level hook registration coverage is deferred: only a live session (claude -p, RUN_TL3)
// exercises it, and check-verification-gate.sh category hook-registration already pins the wiring.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2502-lmg-"));
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

const { MB, ME, bashBody, HDR, BASE, BASE_JS, make } = require("./feature-2502-language-match-gate/common");
const { mkRepo, runHook, row } = make({ ROOT, NEUTRAL, gitInit });

caseBegin("new-file-header-mismatch-blocks", "hooks/block-case-markers.js");
test("a new bash test naming JavaScript code is blocked by both callers", () => {
  row({ rel: "tests/bin/m1.sh", work: bashBody("scope:common", "bin/foo.js"), code: "TEST_LANGUAGE_MISMATCH" });
});
caseEnd();

caseBegin("existing-file-added-js-case-blocks", "hooks/block-case-markers.js");
test("an existing bash test gaining a case on JavaScript code is blocked by both callers", () => {
  const work = bashBody("scope:common", HDR, [["a", "bin/foo.sh"], ["b", "bin/bar.sh"], ["c", "bin/foo.js"]]);
  row({ rel: "tests/bin/m2.sh", head: BASE, work, code: "TEST_LANGUAGE_MISMATCH" });
});
caseEnd();

caseBegin("existing-file-edit-payload-blocks", "hooks/block-case-markers.js");
test("an Edit payload adding a case on JavaScript code to an existing file is blocked", () => {
  const tail = `echo b\n${ME}\n`;
  row({
    rel: "tests/bin/m3.sh", head: BASE, code: "TEST_LANGUAGE_MISMATCH",
    edit: { old_string: tail, new_string: `${tail}${MB} "c" "bin/foo.js"\necho c\n${ME}\n` },
  });
});
caseEnd();

// multiEdit(repo, rel, edits) — the hook on one MultiEdit call whose top-level file_path is rel;
// an element may carry its own file_path (absolute) to edit another file in the same call.
function multiEdit(repo, rel, edits) {
  const abs = path.join(repo, ...rel.split("/"));
  const r = runHook({ tool_name: "MultiEdit", cwd: repo, tool_input: { file_path: abs, edits } });
  return { ...r, show: `hook decision=${r.decision} reason=[${r.reason}] context=[${r.context}] ${r.raw}` };
}
const B_TAIL = `echo b\n${ME}\n`;
const ADD_JS_CASE = { old_string: B_TAIL, new_string: `${B_TAIL}${MB} "c" "bin/foo.js"\necho c\n${ME}\n` };

caseBegin("multiedit-added-js-case-blocks", "hooks/block-case-markers.js");
test("a MultiEdit whose second element adds a case on JavaScript code is blocked", () => {
  const rel = "tests/bin/me1.sh";
  const r = multiEdit(mkRepo({ [rel]: BASE }), rel, [{ old_string: "echo a\n", new_string: "echo a2\n" }, ADD_JS_CASE]);
  assert.strictEqual(r.decision, "block", r.show);
  assert.ok(r.reason.includes("code=TEST_LANGUAGE_MISMATCH") && r.reason.includes(rel), r.show);
});
caseEnd();

caseBegin("multiedit-two-files-blocks-the-mismatched-one", "hooks/block-case-markers.js");
test("a MultiEdit editing two files is blocked on the one gaining a JavaScript case only", () => {
  const ok = "tests/bin/me2.sh";
  const bad = "tests/bin/me3.sh";
  const repo = mkRepo({ [ok]: BASE, [bad]: BASE });
  const badAbs = path.join(repo, ...bad.split("/"));
  const r = multiEdit(repo, ok, [{ old_string: "echo a\n", new_string: "echo a2\n" }, { file_path: badAbs, ...ADD_JS_CASE }]);
  assert.strictEqual(r.decision, "block", r.show);
  assert.ok(r.reason.includes("code=TEST_LANGUAGE_MISMATCH") && r.reason.includes(bad), r.show);
  assert.ok(!r.reason.includes(ok), r.show);
});
caseEnd();

caseBegin("multiedit-body-changes-pass", "hooks/block-case-markers.js");
test("a MultiEdit changing case bodies only (HEAD's JavaScript case included) is approved silently", () => {
  const rel = "tests/bin/me4.sh";
  const r = multiEdit(mkRepo({ [rel]: BASE_JS }), rel, [
    { old_string: "echo a\n", new_string: "echo a2\n" },
    { old_string: "echo j\n", new_string: "echo changed\n" },
  ]);
  assert.strictEqual(r.decision, "approve", r.show);
  assert.strictEqual(r.context, "", r.show);
});
caseEnd();

caseBegin("new-file-invalid-exception-blocks", "hooks/lib/precommit-tests-frontmatter.sh");
test("a new file declaring test-lang-exception:other is blocked by both callers", () => {
  row({ rel: "tests/bin/m4.sh", work: bashBody("scope:common, test-lang-exception:other", "bin/foo.sh"), code: "INVALID_TEST_LANG_EXCEPTION" });
});
caseEnd();

caseBegin("existing-file-tags-changed-to-invalid-blocks", "hooks/lib/precommit-tests-frontmatter.sh");
test("an existing file whose Tags change to test-lang-exception:other is blocked by both callers", () => {
  const work = bashBody("scope:common, test-lang-exception:other", HDR, [["a", "bin/foo.sh"], ["b", "bin/bar.sh"]]);
  row({ rel: "tests/bin/m5.sh", head: BASE, work, code: "INVALID_TEST_LANG_EXCEPTION" });
});
caseEnd();

caseBegin("valid-exception-passes", "hooks/lib/precommit-tests-frontmatter.sh");
test("a new file with test-lang-exception:e2e on JavaScript code passes both callers", () => {
  row({ rel: "tests/bin/m6.sh", work: bashBody("scope:common, test-lang-exception:e2e", "bin/foo.js"), code: null });
});
caseEnd();

caseBegin("existing-mismatch-body-change-passes", "hooks/lib/precommit-tests-frontmatter.sh");
test("a body change to a case HEAD already had on JavaScript code passes both callers", () => {
  const work = bashBody("scope:common", HDR, [["a", "bin/foo.sh"], ["j", "bin/foo.js", "changed"]]);
  row({ rel: "tests/bin/m7.sh", head: BASE_JS, work, code: null });
});
caseEnd();

caseBegin("existing-js-mismatch-retargeted-to-py-passes", "hooks/lib/precommit-tests-frontmatter.sh");
// Plan S4-4: a paired case whose HEAD target was already mismatched is an existing state, so
// moving it from JavaScript to Python code adds no mismatched case and both callers pass it.
test("a case HEAD already had on JavaScript code, moved to Python code, passes both callers", () => {
  const work = bashBody("scope:common", HDR, [["a", "bin/foo.sh"], ["j", "bin/foo.py"]]);
  row({ rel: "tests/bin/m9.sh", head: BASE_JS, work, code: null });
});
caseEnd();

caseBegin("unregistered-language-warn-notice", "hooks/block-case-markers.js");
test("(a) a tests/ file of no registered language passes with TEST_LANGUAGE_UNSUPPORTED in the notice", () => {
  row({ rel: "tests/bin/foo.rb", work: "# Tests: bin/foo.js\n# Tags: scope:common\nputs 1\n", code: null, warn: "TEST_LANGUAGE_UNSUPPORTED" });
});
caseEnd();

caseBegin("same-language-empty-notice", "hooks/block-case-markers.js");
test("(c) a new bash test on bash code passes and the notice stays empty", () => {
  row({ rel: "tests/bin/m8.sh", work: bashBody("scope:common", "bin/foo.sh"), code: null });
});
caseEnd();
