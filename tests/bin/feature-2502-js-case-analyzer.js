#!/usr/bin/env node
"use strict";
// Tests: bin/lib/test-language-parts/js-case-analyzer.js
// Tags: TL2, bin, case-markers, test-language-registry, sweep-tests, js, scope:issue-specific
// The js analyzer answers each caseEmbedRules op as TSV for one test file, called as
// `<op> <file> [args]`: deps (ORDER lines matching the test case reader's ranges, then
// idx<TAB>csv), leftover-defs (line<TAB>name), self-impl <file> <helper> (line<TAB>kind<TAB>
// detail), skip-reason (one word or nothing) and syntax-check (no stdout; rc 0 / 1). The file
// under analysis is read, never run. Every assertion message starts with its test's name.

require("../lib/harness");
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..", "..");
const PARTS = path.join(ROOT, "bin", "lib", "test-language-parts");
const ANALYZER = path.join(PARTS, "js-case-analyzer.js");
const READER = path.join(PARTS, "js-case-reader.js");
const HELPER = path.join(ROOT, "tests", "lib", "harness.js");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2502-js-analyzer-"));
// Marker calls are joined from pieces so this file's own case-marker gate never reads them.
const B = "case" + "Begin";
const E = "case" + "End";

test.after(() => fs.rmSync(TMP, { recursive: true, force: true }));

// Three cases: case 0 uses helperAlpha; case 1 uses helperAlpha, factor and LIMIT; case 2
// uses none of them; helperUnused (line 13) is used by no case.
const SAMPLE = [
  '"use strict";',
  'const { test } = require("node:test");',
  'const assert = require("node:assert");',
  `const { ${B}, ${E} } = require("../lib/harness");`,
  "",
  "const LIMIT = 3;",
  "let factor = 1;",
  "",
  "function helperAlpha() {",
  "  return 1;",
  "}",
  "",
  "function helperUnused() {",
  "  return 9;",
  "}",
  "",
  `${B}("alpha", "bin/a.sh");`,
  'test("alpha", () => {',
  "  assert.strictEqual(helperAlpha(), 1);",
  "});",
  `${E}();`,
  "",
  `${B}("beta", "bin/b.sh");`,
  'test("beta", () => {',
  "  assert.strictEqual(helperAlpha() * factor + 2, LIMIT);",
  "});",
  `${E}();`,
  "",
  `${B}("plain", "bin/c.sh");`,
  'test("plain", () => {',
  "  assert.ok(true);",
  "});",
  `${E}();`,
];

// self-impl: counter-init on 5 (PASS) and 6 (failed); harness-redef on 8 (isolate) and 12
// (gitInit), both exported by tests/lib/harness.js.
const SELF = [
  '"use strict";',
  'const { test } = require("node:test");',
  `const { ${B}, ${E} } = require("../lib/harness");`,
  "",
  "let PASS = 0;",
  "var failed = 0;",
  "",
  "function isolate() {",
  "  return 1;",
  "}",
  "",
  "const gitInit = () => 0;",
  "",
  'test("x", () => {});',
];

// Look-alikes: a destructured require of the helper's names, a renamed counter and helper
// (the accepted limit), a counter inside a function.
const CLEAN = [
  '"use strict";',
  'const { test } = require("node:test");',
  `const { ${B}, ${E}, isolate } = require("../lib/harness");`,
  "",
  "let passCount = 0;",
  "",
  "function myIsolate() {",
  "  let PASS = 0;",
  "  return PASS;",
  "}",
  "",
  'test("x", () => {});',
];

// A file that runs its own loop instead of node:test.
const CUSTOM_RUNNER = [
  '"use strict";',
  "const checks = [];",
  "function check(name, fn) { checks.push([name, fn]); }",
  'check("alpha", () => 1);',
  "let bad = 0;",
  "for (const [name, fn] of checks) { try { fn(); console.log(`ok ${name}`); } catch (e) { bad += 1; } }",
  "process.exit(bad ? 1 : 0);",
];

function sample(name, lines) {
  const file = path.join(TMP, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, lines.join("\n") + "\n");
  return file;
}

function run(name, script, args) {
  assert.ok(fs.existsSync(ANALYZER), `${name}: analyzer ${path.basename(ANALYZER)} missing`);
  return spawnSync(process.execPath, [script, ...args], { encoding: "utf8", timeout: 60000 });
}

const rows = (r) => r.stdout.split(/\r?\n/).filter((l) => l !== "").map((l) => l.split("\t"));

function analyzeOk(name, op, file, extra = []) {
  const r = run(name, ANALYZER, [op, file, ...extra]);
  assert.strictEqual(r.status, 0, `${name}: ${op} exit code; stderr: ${r.stderr}`);
  return rows(r);
}

function check(name, body) {
  test(name, () => body(name));
}

check("deps ORDER lines match the test case reader's ranges and come first", (n) => {
  const file = sample("order/sample.js", SAMPLE);
  const got = analyzeOk(n, "deps", file);
  const ranges = rows(run(n, READER, [file])).filter((c) => c[0] === "CASE").map((c, i) => [String(i), c[3], c[4]]);
  assert.deepStrictEqual(ranges, [["0", "17", "21"], ["1", "23", "27"], ["2", "29", "33"]], `${n}: reader ranges`);
  const order = got.filter((c) => c[0] === "ORDER").map((c) => c.slice(1));
  assert.deepStrictEqual(order, ranges, `${n}: ORDER lines equal the reader's ranges`);
  const firstDep = got.findIndex((c) => c[0] !== "ORDER");
  assert.ok(got.slice(firstDep).every((c) => c[0] !== "ORDER"), `${n}: ORDER lines come first`);
});

check("deps name the top-level declarations each case uses", (n) => {
  const got = analyzeOk(n, "deps", sample("deps/sample.js", SAMPLE)).filter((c) => c[0] !== "ORDER");
  const deps = Object.fromEntries(got.map((c) => [c[0], new Set((c[1] || "").split(",").filter(Boolean))]));
  assert.deepStrictEqual(Object.keys(deps), ["0", "1", "2"], `${n}: one idx row per case`);
  assert.ok(deps["0"].has("helperAlpha"), `${n}: case 0 uses helperAlpha`);
  for (const x of ["factor", "LIMIT", "helperUnused"]) assert.ok(!deps["0"].has(x), `${n}: case 0 lacks ${x}`);
  for (const x of ["helperAlpha", "factor", "LIMIT"]) assert.ok(deps["1"].has(x), `${n}: case 1 has ${x}`);
  for (const x of ["helperAlpha", "factor", "LIMIT", "helperUnused"]) assert.ok(!deps["2"].has(x), `${n}: case 2 lacks ${x}`);
  for (const k of ["0", "1", "2"]) assert.ok(!deps[k].has("helperUnused"), `${n}: no case uses helperUnused`);
});

check("leftover-defs name the declaration no case uses", (n) => {
  const got = analyzeOk(n, "leftover-defs", sample("left/sample.js", SAMPLE));
  assert.deepStrictEqual(got, [["13", "helperUnused"]], `${n}: leftover-defs`);
});

check("self-impl reports counters and redefinitions of the helper's exports", (n) => {
  const got = analyzeOk(n, "self-impl", sample("self/self.js", SELF), [HELPER]);
  assert.deepStrictEqual(got.map((c) => [c[0], c[1]]), [["5", "counter-init"], ["6", "counter-init"], ["8", "harness-redef"], ["12", "harness-redef"]], `${n}: detections`);
  assert.ok(got[0][2].includes("PASS") && got[1][2].includes("failed"), `${n}: counter details`);
  assert.deepStrictEqual([got[2][2], got[3][2]], ["isolate", "gitInit"], `${n}: harness-redef details`);
});

check("self-impl does not report a destructured require or renamed look-alikes", (n) => {
  assert.deepStrictEqual(analyzeOk(n, "self-impl", sample("self/clean.js", CLEAN), [HELPER]), [], `${n}: no detection`);
});

const skipCases = [
  { name: "skip-reason names a runner outside node:test", lines: CUSTOM_RUNNER, want: [["custom-runner"]] },
  { name: "skip-reason is empty for a node:test file", lines: SAMPLE, want: [] },
];
for (const { name, lines, want } of skipCases) {
  check(name, (n) => assert.deepStrictEqual(analyzeOk(n, "skip-reason", sample("skip/s.js", lines)), want, `${n}: skip-reason`));
}

const synCases = [
  { name: "syntax-check passes a valid file with no stdout", lines: SAMPLE, code: 0 },
  { name: "syntax-check fails an unclosed parameter list", lines: ['"use strict";', "function f( {"], code: 1 },
  { name: "syntax-check fails a stray closing brace", lines: ['"use strict";', "const a = 1;", "}"], code: 1 },
];
for (const { name, lines, code } of synCases) {
  check(name, (n) => {
    const r = run(n, ANALYZER, ["syntax-check", sample("syn/s.js", lines)]);
    assert.strictEqual(r.status, code, `${n}: exit code; stderr: ${r.stderr}`);
    assert.strictEqual(r.stdout, "", `${n}: no stdout`);
    assert.strictEqual(r.stderr !== "", code === 1, `${n}: stderr carries the reason only on failure`);
  });
}

// case-count (#2502 S4-4b): the column-0 marker calls in the code region; one number, rc 1
// when there is none. Marker text inside a block comment or a template literal is no unit.
const COUNT_HIDDEN = [
  ...SAMPLE,
  "/*",
  `${B}("in-comment", "bin/a.sh");`,
  "*/",
  "const doc = `",
  `${B}("in-template", "bin/a.sh");`,
  "`;",
];
const countCases = [
  { name: "case-count counts the three marker calls", lines: SAMPLE, code: 0, out: "3" },
  { name: "case-count skips marker text in block comments and templates", lines: COUNT_HIDDEN, code: 0, out: "3" },
  { name: "case-count fails a file without case markers", lines: CUSTOM_RUNNER, code: 1, out: "" },
];
for (const { name, lines, code, out } of countCases) {
  check(name, (n) => {
    const r = run(n, ANALYZER, ["case-count", sample("count/c.js", lines)]);
    assert.strictEqual(r.status, code, `${n}: exit code; stderr: ${r.stderr}`);
    assert.strictEqual(r.stdout.trim(), out, `${n}: case-count stdout`);
  });
}

check("the file under analysis is never run", (n) => {
  const sentinel = path.join(TMP, "executed.flag");
  const file = sample("side/side.js", [`require("fs").writeFileSync(${JSON.stringify(sentinel)}, "ran");`, ...SAMPLE.slice(1)]);
  for (const op of ["deps", "leftover-defs", "skip-reason", "syntax-check"]) analyzeOk(n, op, file);
  analyzeOk(n, "self-impl", file, [HELPER]);
  assert.strictEqual(fs.existsSync(sentinel), false, `${n}: sentinel must not be written`);
});
