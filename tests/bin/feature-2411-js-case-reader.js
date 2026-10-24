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
const DOLLAR_BRACE = "$" + "{";
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
// CASE rows carry 7 columns: CASE, name, target, begin, end, deps, reason (#2673 dropped idx).
const TWO_CASES_ROWS = [
  ["CASE", "alpha", "bin/a.sh", "3", "5", "", ""],
  ["CASE", "beta", "bin/lib/b.js", "7", "10", "", ""],
];
const ALPHA = (from, to) => [["CASE", "alpha", "bin/a.sh", String(from), String(to), "", ""]];
// Template and comment samples are joined from constants so this file never holds them itself.
const MARKER = [begin("alpha", "bin/a.sh"), END];
const tpl = (body) => BACKTICK + body + BACKTICK;
// One case built twice with the same name: the reader passes both through (#2673).
const DUP_NAME = [begin("alpha", "bin/a.sh"), END, begin("alpha", "bin/b.sh"), END];

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
  { name: "a comment opener inside a template does not open a comment", file: "tpl-comment.js", lines: ["const s = " + tpl(COMMENT_OPEN) + ";", ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "a line-comment opener inside a template does not end the line", file: "tpl-slashes.js", lines: ["const u = " + tpl("http:" + "//x") + ";", ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "a template nested inside an interpolation closes with its host", file: "tpl-nested.js", lines: ["const t = " + tpl("a${f(" + tpl(COMMENT_OPEN) + ")}b") + ";", ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "braces inside an interpolation do not close it early", file: "tpl-braces.js", lines: ["const o = " + tpl("${ {a: 1}.a }") + ";", ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "a marker after a closed multi-line template holding a comment opener counts", file: "tpl-multiline.js", lines: ["const m = " + BACKTICK, "x " + COMMENT_OPEN + " y", BACKTICK + ";", ...MARKER], state: "conforming", rows: ALPHA(4, 5) },
  { name: "duplicate names pass through the reader (the shared state rule rejects them)", file: "dup-name.js", lines: DUP_NAME, state: "conforming", rows: [["CASE", "alpha", "bin/a.sh", "1", "2", "", ""], ["CASE", "alpha", "bin/b.sh", "3", "4", "", ""]] },
  // Ordinary code lines that only look like region openers leave the scan in code (#2673 scanCode).
  { name: "a comment opener inside a double-quoted string does not open a comment", file: "str-comment.js", lines: ['const s = "' + COMMENT_OPEN + '";', ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "a backtick inside a single-quoted string does not open a template", file: "str-backtick.js", lines: ["const q = '" + BACKTICK + "';", ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "an interpolation opener inside a double-quoted string opens nothing", file: "str-interp.js", lines: ['const d = "' + DOLLAR_BRACE + '";', ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "an escaped quote does not end a string before a comment opener", file: "str-escaped-quote.js", lines: ['const e = "a\\"' + COMMENT_OPEN + '";', ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "a line comment holding a comment opener and a backtick opens nothing", file: "line-comment.js", lines: ["// note " + COMMENT_OPEN + " and " + BACKTICK, ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "a block comment closed on its own line leaves the code after it as code", file: "block-one-line.js", lines: [COMMENT_OPEN + " x " + COMMENT_CLOSE + " check();", ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
  { name: "an escaped backtick inside a template neither closes it nor lets a comment opener count", file: "tpl-escaped-backtick.js", lines: ["const g = " + tpl("a\\" + BACKTICK + " " + COMMENT_OPEN) + ";", ...MARKER], state: "conforming", rows: ALPHA(2, 3) },
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
  { name: "a comment opened after a template closes on the same line still makes a call-looking line uncertain", open: "const s = " + tpl("x") + "; " + COMMENT_OPEN, close: COMMENT_CLOSE },
  { name: "a call-looking line while an interpolation stays open across lines is uncertain", open: "const t = " + BACKTICK + "a${f(", close: ")}b" + BACKTICK + ";" },
];
for (const { name, open, close } of uncertainCases) {
  check(name, (n) => {
    const out = read(n, sample("uncertain.js", [open, begin("alpha", "bin/a.sh"), END, close]));
    assert.strictEqual(out.status, 0, `${n}: exit code`);
    assert.strictEqual(out.files.length, 1, `${n}: exactly one FILE line`);
    assert.strictEqual(out.files[0][1], "uncertain", `${n}: state`);
  });
}

// #2712: a TAB, CR or LF that reaches a name or a target would split the TSV, so the reader
// reports grammar at the begin line itself (LF arrives through a multi-line template).
const delimiterCases = [
  { name: "a TAB in the name is grammar", call: [begin("al\tpha", "bin/a.sh")] },
  { name: "a CR in the name is grammar", call: [begin("al\rpha", "bin/a.sh")] },
  { name: "an LF in a template name is grammar", call: [`${BEGIN}(${BACKTICK}al`, `pha${BACKTICK}, "bin/a.sh");`] },
  { name: "a TAB in the target is grammar", call: [begin("alpha", "bin/a\t.sh")] },
  { name: "a CR in the target is grammar", call: [begin("alpha", "bin/a\r.sh")] },
  { name: "an LF in a template target is grammar", call: [`${BEGIN}("alpha", ${BACKTICK}bin/a`, `.sh${BACKTICK});`] },
];
for (const { name, call } of delimiterCases) {
  check(name, (n) => assertMalformed(n, sample("delimiter.js", ["check(0);", ...call, END]), "grammar", 2));
}
// Accept: an escaped backslash is the two characters `\t`, not a TAB.
check("an escaped backslash-t in the name is not a delimiter", (n) =>
  assertRecords(n, sample("escaped-t.js", [begin("al\\\\tpha", "bin/a.sh"), END]), "conforming", [["CASE", "al\\tpha", "bin/a.sh", "1", "2", "", ""]]));

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
