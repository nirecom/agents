"use strict";
// bin/lib/test-language-parts/js-case-scan.js — the js case enumeration, shared by
// js-case-reader.js and js-case-analyzer.js so both see one case order.
// A line reader, not a parser: a case is a column-0 `caseBegin("<name>", "<target>");` ...
// `caseEnd();` pair of tests/lib/harness.js. Block comment and template state is tracked across
// lines, through nested `${}`; a call-looking line inside a block comment, a template or a `${}`
// cannot be settled by reading lines, so the file reads `uncertain`.

const fs = require("fs");

const STR = String.raw`"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|` + "`(?:[^`\\\\$]|\\\\.)*`";
const TAIL = String.raw`\s*\)\s*;?\s*(?:\/\/.*)?$`;
const BEGIN_ARGS = new RegExp(String.raw`^caseBegin\(\s*(${STR})((?:\s*,\s*(?:${STR}))*)${TAIL}`);
const NEXT_ARG = new RegExp(String.raw`\s*,\s*(${STR})`, "g");
const END_CALL = new RegExp(String.raw`^caseEnd\(${TAIL}`);
const CALL_LOOKING = /^\s*case(?:Begin|End)\(/;
// The "Case target path rule" section of docs/architecture/claude-code/test-language-registry.md owns TARGET_OK.
const TARGET_OK = /^[A-Za-z0-9._/-]+$/;
const RECORD_DELIMITER = /[\t\r\n]/;

// Thrown to end the scan with its verdict; scanLines catches it.
class Verdict {
  constructor(state, line, reason, cases) {
    this.state = state;
    this.line = line;
    this.reason = reason;
    this.cases = cases || [];
  }
}

function finish(state, line, reason, cases) {
  throw new Verdict(state, line, reason, cases);
}

// The literal's value, or null when it holds an escape other than a quote or a backslash.
function constantValue(literal) {
  const body = literal.slice(1, -1);
  if (/\\/.test(body.replace(/\\[\\"'`]/g, ""))) return null;
  return body.replace(/\\(.)/g, "$1");
}

function targetIsValid(target) {
  if (!TARGET_OK.test(target) || target.startsWith("/")) return false;
  const parts = target.split("/");
  return parts[0] !== "." && !parts.includes("..");
}

// Walks one line and returns the region stack after it. Entries: { kind: "comment" },
// { kind: "template" }, { kind: "expr", depth } (inside `${`, depth = open inner `{`); empty = code.
// When `code` (an array) is given, the line's code characters are pushed onto it; comments and
// string or template text become one space each.
function scanCode(raw, stack, code) {
  const s = stack.map((e) => ({ ...e }));
  const emit = code ? (t) => code.push(t) : () => {};
  let i = 0;
  while (i < raw.length) {
    const top = s[s.length - 1];
    const ch = raw[i];
    const two = raw.slice(i, i + 2);
    if (top && top.kind === "comment") {
      if (two === "*/") {
        s.pop();
        emit(" ");
        i += 2;
      } else i += 1;
      continue;
    }
    if (top && top.kind === "template") {
      if (ch === "\\") i += 2;
      else if (ch === "`") {
        s.pop();
        emit(" ");
        i += 1;
      } else if (two === "${") {
        s.push({ kind: "expr", depth: 0 });
        emit(" ");
        i += 2;
      } else i += 1;
      continue;
    }
    if (two === "//") break;
    if (two === "/*") {
      s.push({ kind: "comment" });
      i += 2;
      continue;
    }
    if (ch === '"' || ch === "'") {
      i += 1;
      while (i < raw.length && raw[i] !== ch) i += raw[i] === "\\" ? 2 : 1;
      emit(" ");
      i += 1;
      continue;
    }
    if (ch === "`") s.push({ kind: "template" });
    else if (top && ch === "{") top.depth += 1;
    else if (top && ch === "}") {
      if (top.depth === 0) {
        s.pop();
        i += 1;
        continue;
      }
      top.depth -= 1;
    }
    if (ch !== "`") emit(ch);
    i += 1;
  }
  return s;
}

// The caseBegin call text from line index i: a template literal left open joins the next lines,
// so an LF inside a name or a value reaches the delimiter check instead of reading `constant`.
function beginText(lines, i) {
  let text = lines[i];
  for (let j = i + 1; j < lines.length && scanCode(text, []).some((e) => e.kind === "template"); j += 1) {
    text += `\n${lines[j]}`;
  }
  return text;
}

function readBegin(text, lineNo) {
  const m = BEGIN_ARGS.exec(text);
  if (!m) finish("malformed", lineNo, "constant");
  const literals = [m[1], ...[...m[2].matchAll(NEXT_ARG)].map((x) => x[1])];
  const values = literals.map(constantValue);
  if (values.includes(null)) finish("malformed", lineNo, "constant");
  if (values.length > 2) finish("malformed", lineNo, "duplicate-target");
  return values;
}

function walk(lines) {
  const cases = [];
  let open = null;
  let stack = [];
  for (const [i, raw] of lines.entries()) {
    const lineNo = i + 1;
    if (stack.length) {
      if (CALL_LOOKING.test(raw)) finish("uncertain", lineNo, "grammar");
      stack = scanCode(raw, stack);
      continue;
    }
    if (raw.startsWith("caseBegin(")) {
      if (open) finish("malformed", lineNo, "depth");
      const [name, target] = readBegin(beginText(lines, i), lineNo);
      if (name === "") finish("malformed", lineNo, "grammar");
      // A TAB, CR or LF would split the record line, so it reads grammar ahead of the target rule.
      if (RECORD_DELIMITER.test(`${name}${target === undefined ? "" : target}`)) {
        finish("malformed", lineNo, "grammar");
      }
      if (target === undefined) finish("malformed", lineNo, "missing-target");
      if (!targetIsValid(target)) finish("malformed", lineNo, "target");
      open = { name, target, begin: lineNo };
      continue;
    }
    if (END_CALL.test(raw)) {
      if (!open) finish("malformed", lineNo, "balance");
      cases.push({ ...open, end: lineNo });
      open = null;
      continue;
    }
    if (/^\s+caseBegin\(/.test(raw) && readBegin(raw.trimStart(), lineNo).length > 1) {
      finish("malformed", lineNo, "nested-target");
    }
    stack = scanCode(raw, stack);
  }
  if (open) finish("malformed", open.begin, "balance");
  finish(cases.length ? "conforming" : "none", "", "", cases);
}

// The column-0 caseBegin( lines in the code region (block comments and templates skipped as walk does).
function countBegins(lines) {
  let n = 0;
  let stack = [];
  for (const raw of lines) {
    if (!stack.length && raw.startsWith("caseBegin(")) n += 1;
    stack = scanCode(raw, stack);
  }
  return n;
}

// The file's lines: a leading BOM dropped, split on LF or CRLF. Throws when unreadable.
function readLines(file) {
  const text = fs.readFileSync(file, "utf8");
  const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  return body.split(/\r?\n/);
}

// The verdict of the lines: { state, line, reason, cases: [{ name, target, begin, end }] }.
function scanLines(lines) {
  try {
    walk(lines);
  } catch (err) {
    if (err instanceof Verdict) return err;
    throw err;
  }
  throw new Error("js-case-scan: no verdict");
}

module.exports = { countBegins, readLines, scanCode, scanLines };
