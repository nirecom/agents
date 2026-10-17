#!/usr/bin/env node
"use strict";
// Tests: bin/lib/test-language-parts/js-case-reader.js
// Tags: TL2, bin, case-markers, test-language-registry, js, scope:issue-specific
// The JavaScript case reader is a line reader: it reports the column-0 paired calls of
// tests/lib/harness.js as TSV (one FILE line, one CASE line per case) and never runs the file.
// Every assertion message starts with the name of its case, so a failure names its table row.

const { caseBegin, caseEnd } = require("../lib/harness");
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const READER = path.join(__dirname, "..", "..", "bin", "lib", "test-language-parts", "js-case-reader.js");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2411-js-reader-"));
const BACKTICK = String.fromCharCode(96);
const COMMENT_OPEN = "/" + "*";
const COMMENT_CLOSE = "*" + "/";
const BEGIN = "caseBegin";
const END = "caseEnd();";

test.after(() => fs.rmSync(TMP, { recursive: true, force: true }));

function begin(name, target) {
  return `${BEGIN}("${name}", "${target}");`;
}

function sample(name, lines, { eol = "\n", bom = false } = {}) {
  const file = path.join(TMP, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const body = lines.length === 0 ? "" : lines.join(eol) + eol;
  fs.writeFileSync(file, (bom ? "\uFEFF" : "") + body);
  return file;
}

// check(name, body) — one test whose body receives its own name for the assertion messages.
function check(name, body) {
  test(name, () => body(name));
}

function read(name, file) {
  const r = spawnSync(process.execPath, [READER, file], { encoding: "utf8", timeout: 60000 });
  const rows = r.stdout.split(/\r?\n/).filter((l) => l !== "").map((l) => l.split("\t"));
  const stray = rows.filter((c) => c[0] !== "FILE" && c[0] !== "CASE");
  assert.deepStrictEqual(stray, [], `${name}: unexpected stdout lines; stderr: ${r.stderr}`);
  return {
    status: r.status,
    files: rows.filter((c) => c[0] === "FILE"),
    cases: rows.filter((c) => c[0] === "CASE"),
  };
}

function assertRecords(name, file, state, cases) {
  const out = read(name, file);
  assert.strictEqual(out.status, 0, `${name}: exit code`);
  assert.deepStrictEqual(out.files, [["FILE", state, "", ""]], `${name}: FILE line`);
  assert.deepStrictEqual(out.cases, cases, `${name}: CASE lines`);
}

function assertMalformed(name, file, reason, line) {
  const out = read(name, file);
  assert.strictEqual(out.status, 0, `${name}: exit code`);
  assert.strictEqual(out.files.length, 1, `${name}: exactly one FILE line`);
  const [, state, gotLine, gotReason] = out.files[0];
  assert.deepStrictEqual([state, gotReason], ["malformed", reason], `${name}: state and reason`);
  if (line === undefined) assert.match(gotLine, /^[1-9][0-9]*$/, `${name}: line number`);
  else assert.strictEqual(gotLine, String(line), `${name}: line number`);
  assert.deepStrictEqual(out.cases, [], `${name}: no CASE line`);
}

const TWO_CASES = [
  'const { caseBegin, caseEnd } = require("../lib/harness");',
  "",
  begin("alpha", "bin/a.sh"),
  "check(1);",
  END,
  "",
  begin("beta", "bin/lib/b.js"),
  "check(2);",
  "check(3);",
  END,
];
const TWO_CASES_ROWS = [
  ["CASE", "0", "alpha", "bin/a.sh", "3", "5", "", ""],
  ["CASE", "1", "beta", "bin/lib/b.js", "7", "10", "", ""],
];
const ALPHA = (from, to) => [["CASE", "0", "alpha", "bin/a.sh", String(from), String(to), "", ""]];

caseBegin("js-case-reader", "bin/lib/test-language-parts/js-case-reader.js");

const recordCases = [
  { name: "no markers is none with no CASE line", file: "none.js", lines: ['"use strict";', "check(1);"], state: "none", rows: [] },
  { name: "empty file is none", file: "empty.js", lines: [], state: "none", rows: [] },
  { name: "two cases are conforming with begin-to-end line ranges and an empty deps column", file: "two.js", lines: TWO_CASES, state: "conforming", rows: TWO_CASES_ROWS },
  { name: "CRLF line endings give the same records as the plain file", file: "crlf.js", lines: TWO_CASES, opts: { eol: "\r\n" }, state: "conforming", rows: TWO_CASES_ROWS },
  { name: "a UTF-8 BOM gives the same records as the plain file", file: "bom.js", lines: TWO_CASES, opts: { bom: true }, state: "conforming", rows: TWO_CASES_ROWS },
  { name: "a BOM with CRLF gives the same records as the plain file", file: "bom-crlf.js", lines: TWO_CASES, opts: { bom: true, eol: "\r\n" }, state: "conforming", rows: TWO_CASES_ROWS },
  { name: "a file path holding a space gives the same records as the plain file", file: path.join("dir with space", "two cases.js"), lines: TWO_CASES, state: "conforming", rows: TWO_CASES_ROWS },
  { name: "a BOM before a begin call on line 1 still counts the call", file: "bom-first.js", lines: [begin("alpha", "bin/a.sh"), END], opts: { bom: true }, state: "conforming", rows: ALPHA(1, 2) },
  { name: "an indented end call does not close the open case", file: "indented-end.js", lines: [begin("alpha", "bin/a.sh"), "if (ready) {", `  ${END}`, "}", END], state: "conforming", rows: ALPHA(1, 5) },
  { name: "calls reached through another name are not delimiters", file: "via-variable.js", lines: ['const h = require("../lib/harness");', 'h.caseBegin("alpha", "bin/a.sh");', "h.caseEnd();"], state: "none", rows: [] },
  { name: "JavaScript syntax is not checked", file: "broken-syntax.js", lines: ["function (((", begin("alpha", "bin/a.sh"), "}}}", END], state: "conforming", rows: ALPHA(2, 4) },
];
for (const { name, file, lines, opts, state, rows } of recordCases) {
  check(name, (n) => assertRecords(n, sample(file, lines, opts), state, rows));
}

const constantCases = [
  { name: "non-constant argument is constant: name is an identifier", call: `${BEGIN}(name, "bin/a.sh");` },
  { name: "non-constant argument is constant: target is an identifier", call: `${BEGIN}("alpha", target);` },
  { name: "non-constant argument is constant: name is a concatenation", call: `${BEGIN}("al" + suffix, "bin/a.sh");` },
  { name: "non-constant argument is constant: target is a concatenation", call: `${BEGIN}("alpha", "bin/" + leaf);` },
  { name: "non-constant argument is constant: target is an interpolating template", call: `${BEGIN}("alpha", ${BACKTICK}bin/\${leaf}${BACKTICK});` },
];
for (const { name, call } of constantCases) {
  check(name, (n) => assertMalformed(n, sample("constant.js", ["check(0);", call, "check(1);", END]), "constant", 2));
}

const targetCases = [
  { name: "invalid target path is target: empty", target: "" },
  { name: "invalid target path is target: absolute", target: "/abs/a.sh" },
  { name: "invalid target path is target: drive letter", target: "C:/abs/a.sh" },
  { name: "invalid target path is target: backslash", target: "bin\\\\a.sh" },
  { name: "invalid target path is target: leading dot-dot", target: "../a.sh" },
  { name: "invalid target path is target: inner dot-dot", target: "bin/../a.sh" },
  { name: "invalid target path is target: trailing dot-dot", target: "bin/.." },
  { name: "invalid target path is target: semicolon", target: "bin/a.sh;id" },
  { name: "invalid target path is target: dollar", target: "bin/$HOME.sh" },
  { name: "invalid target path is target: pipe", target: "bin/a|b.sh" },
  { name: "invalid target path is target: ampersand", target: "bin/a&b.sh" },
  { name: "invalid target path is target: redirect", target: "bin/a>b.sh" },
  { name: "invalid target path is target: parenthesis", target: "bin/a(b).sh" },
  { name: "invalid target path is target: space", target: "bin/a b.sh" },
];
for (const { name, target } of targetCases) {
  check(name, (n) => assertMalformed(n, sample("target.js", [begin("alpha", target), "check(1);", END]), "target", 1));
}

const malformedCases = [
  { name: "a begin without a target beside a begin with one is missing-target", file: "missing.js", lines: [begin("alpha", "bin/a.sh"), END, `${BEGIN}("beta");`, END], reason: "missing-target", line: 3 },
  { name: "two targets on one begin is duplicate-target", file: "duplicate.js", lines: [`${BEGIN}("alpha", "bin/a.sh", "bin/b.sh");`, END], reason: "duplicate-target", line: 1 },
  { name: "an indented begin carrying a target is nested-target", file: "nested.js", lines: ["function wrap() {", `  ${begin("alpha", "bin/a.sh")}`, `  ${END}`, "}"], reason: "nested-target", line: 2 },
  { name: "a begin without an end is balance", file: "balance.js", lines: [begin("alpha", "bin/a.sh"), "check(1);"], reason: "balance", line: undefined },
  { name: "a begin inside an open case is depth", file: "depth.js", lines: [begin("alpha", "bin/a.sh"), begin("beta", "bin/b.sh"), END, END], reason: "depth", line: 2 },
];
for (const { name, file, lines, reason, line } of malformedCases) {
  check(name, (n) => assertMalformed(n, sample(file, lines), reason, line));
}

const uncertainCases = [
  { name: "a call-looking line inside a block comment is uncertain", open: COMMENT_OPEN, close: COMMENT_CLOSE },
  { name: "a call-looking line inside a multi-line template string is uncertain", open: `const text = ${BACKTICK}`, close: `${BACKTICK};` },
];
for (const { name, open, close } of uncertainCases) {
  check(name, (n) => {
    const out = read(n, sample("uncertain.js", [open, begin("alpha", "bin/a.sh"), END, close]));
    assert.strictEqual(out.status, 0, `${n}: exit code`);
    assert.strictEqual(out.files.length, 1, `${n}: exactly one FILE line`);
    assert.strictEqual(out.files[0][1], "uncertain", `${n}: state`);
  });
}

check("the file under read is never executed", (n) => {
  const sentinel = path.join(TMP, "executed.flag");
  const lines = [`require("fs").writeFileSync(${JSON.stringify(sentinel)}, "ran");`, begin("alpha", "bin/a.sh"), END];
  assertRecords(n, sample("side-effect.js", lines), "conforming", ALPHA(2, 3));
  assert.strictEqual(fs.existsSync(sentinel), false, `${n}: sentinel must not be written`);
});

check("an unreadable path exits non-zero and prints no FILE line", (n) => {
  const out = read(n, path.join(TMP, "absent.js"));
  assert.notStrictEqual(out.status, 0, `${n}: exit code`);
  assert.deepStrictEqual(out.files, [], `${n}: no FILE line`);
});

caseEnd();
