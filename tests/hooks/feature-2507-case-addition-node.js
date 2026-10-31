"use strict";
// Tests: hooks/lib/test-gates/language-match/case-addition.js
// Tags: TL2, hooks, test-gates, test-language-match, case-markers, test-language-registry, table-driven, node-precommit, scope:issue-specific
// #2507: the case-addition judgment moved in-process (it was bin/lib/test-language-match/case-addition.sh).
// What the retired bash stub checkout pinned is pinned here by patching the shared parts module:
// a deps op that fails makes a marked version count as not conforming, and a case-count answer of
// rc 69 (runtime missing) falls back to code lines. codeLines skips blanks and comment lines.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.join(__dirname, "..", "..");
const P = require(path.join(REPO, "hooks", "lib", "test-gates", "parts"));
const S = require(path.join(REPO, "hooks", "lib", "test-gates", "source"));
const LM = require(path.join(REPO, "hooks", "lib", "test-gates", "language-match"));

const restore = isolate();
after(() => restore());

const realEmbed = P.embed;
// withEmbed(fake, fn) — P.embed replaced by fake(real, entry, op, file, opts) for fn's duration.
function withEmbed(fake, fn) {
  P.embed = (...a) => fake(realEmbed, ...a);
  try {
    return fn();
  } finally {
    P.embed = realEmbed;
  }
}

const mem = (name, lines) => S.mem(name, `${lines.join("\n")}\n`);
const MB = "case" + "_begin"; // split so the fixture text is never read as a marker
const ME = "case" + "_end";
const SRC = 'source "$(dirname "$0")/../../tests/lib/harness.sh"';
const H_A = ["#!/usr/bin/env bash", "# Tests: bin/a.sh, bin/foo.sh", "# Tags: scope:common", SRC];
const mk = (n, body) => [`${MB} "${n}" "bin/a.sh"`, body, ME];

const judged = (file, name, head) => LM.check(file, name, head, { root: REPO });
const added = (r) => r.lines.filter((l) => l.text.endsWith("code=CASE_ADDED_WITHOUT_MARKERS")).map((l) => l.text);
const addedLine = (name, basis, marker) =>
  `HIGH: ${name}: case added to a test file without valid case markers (${basis}); add ${marker} to every case first, then each case's target is checked code=CASE_ADDED_WITHOUT_MARKERS`;

// The deps op fails on any version holding a `# deps-fail` line; every other call is the real part.
const depsFails = (real, entry, op, file, opts) =>
  op === "deps" && S.textOf(file).includes("# deps-fail") ? { rc: 1, stdout: "", stderr: "stub" } : real(entry, op, file, opts);

caseBegin("deps-op-failure-enters-the-judgment", "hooks/lib/test-gates/language-match/case-addition.js");
test("a marked version whose deps op fails is judged by code lines", () => {
  const head = mem("d.sh", [...H_A, ...mk("a", "echo a"), ...mk("b", "echo b")]);
  const work = mem("d.sh", [...H_A, "# deps-fail", ...mk("a", "echo a"), ...mk("b", "echo b"), ...mk("c", "echo c")]);
  const r = withEmbed(depsFails, () => judged(work, "tests/bin/d1.sh", head));
  assert.strictEqual(r.violation, true, JSON.stringify(r.lines));
  assert.deepStrictEqual(added(r), [addedLine("tests/bin/d1.sh", "case count unavailable: no case unit; code lines 7 -> 10", "case_begin/case_end")]);
  const same = mem("d.sh", [...H_A, "# deps-fail", ...mk("a", "echo a"), ...mk("b", "echo bb")]);
  const r2 = withEmbed(depsFails, () => judged(same, "tests/bin/d2.sh", head));
  assert.deepStrictEqual(r2, { lines: [], violation: false, infra: false });
});
caseEnd();

const P_H = ["# Tests: bin/m.ps1, bin/n.ps1", "# Tags: scope:common", 'BeforeAll { function Invoke-Tool { & pwsh -File "$PSScriptRoot/../../bin/m.ps1" } }'];
const desc = (n, body) => [`Describe '${n}' {`, `    It 'x' { ${body} }`, "}"];
// case-count answers rc 69 (runtime missing) for every version.
const noRuntime = (real, entry, op, file, opts) => (op === "case-count" ? { rc: 69, stdout: "", stderr: "" } : real(entry, op, file, opts));

caseBegin("pester-no-runtime-falls-back-to-code-lines", "hooks/lib/test-gates/language-match/case-addition.js");
test("a pester case-count of rc 69 falls back to code lines", () => {
  const head = mem("foo.Tests.ps1", [...P_H, ...desc("one", "1 | Should -Be 1"), ...desc("two", "2 | Should -Be 2")]);
  const work = mem("foo.Tests.ps1", [...P_H, ...desc("one", "1 | Should -Be 1"), ...desc("two", "2 | Should -Be 2"), ...desc("three", "Invoke-Tool")]);
  const name = "tests/bin/foo.Tests.ps1";
  const r = withEmbed(noRuntime, () => judged(work, name, head));
  assert.strictEqual(added(r).length, 1, JSON.stringify(r.lines));
  assert.ok(added(r)[0].includes("(case count unavailable: runtime not installed; code lines 7 -> 10)"), added(r)[0]);
  const value = mem("foo.Tests.ps1", [...P_H, ...desc("one", "1 | Should -Be 1"), ...desc("two", "2 | Should -Be 3")]);
  const r2 = withEmbed(noRuntime, () => judged(value, name, head));
  assert.deepStrictEqual(added(r2), [], JSON.stringify(r2.lines));
});
caseEnd();

caseBegin("code-lines-skip-blank-and-comment-lines", "hooks/lib/test-gates/language-match/case-addition.js");
test("codeLines counts lines that are neither blank nor comments in the match-path's prefix", () => {
  const rows = [
    ["lines.sh", "tests/bin/x.sh", ["#!/usr/bin/env bash", "# Tests: bin/a.sh", "", "   # indented comment", "echo a", "  echo b", ""], 2],
    ["lines.js", "tests/bin/x.js", ['"use strict";', "// Tests: bin/a.sh", "  // indented comment", "", "const a = 1;", "# not a js comment"], 3],
    ["lines.py", "tests/bin/test_x.py", ["# Tests: bin/a.sh", '"""A docstring is code."""', "", "import os", "    # indented comment", "def test_a():", "    pass"], 4],
  ];
  for (const [f, match, lines, want] of rows) assert.strictEqual(LM.codeLines(mem(f, lines), match), want, `${f} as ${match}`);
});
caseEnd();
