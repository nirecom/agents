"use strict";
// bin/lib/test-language-parts/js-case-reader.js <file> — the js entry's case reader child.
// A line reader, not a parser: it reports the column-0 `caseBegin("<name>", "<target>");` ...
// `caseEnd();` pairs of tests/lib/harness.js and never runs or parses the file. Prints
//   FILE\t<state>\t<line>\t<reason>   and, when conforming, one
//   CASE\t<name>\t<target>\t<begin>\t<end>\t\t   per pair, in file order.
// Block comment and template state is tracked across lines, through nested `${}`; a call-looking
// line inside a block comment, a template or a `${}` cannot be settled by reading lines, so the
// file is reported as `uncertain`. Exit 1: unreadable file.

const fs = require("fs");

const STR = String.raw`"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|` + "`(?:[^`\\\\$]|\\\\.)*`";
const TAIL = String.raw`\s*\)\s*;?\s*(?:\/\/.*)?$`;
const BEGIN_ARGS = new RegExp(String.raw`^caseBegin\(\s*(${STR})((?:\s*,\s*(?:${STR}))*)${TAIL}`);
const NEXT_ARG = new RegExp(String.raw`\s*,\s*(${STR})`, "g");
const END_CALL = new RegExp(String.raw`^caseEnd\(${TAIL}`);
const CALL_LOOKING = /^\s*case(?:Begin|End)\(/;
const TARGET_OK = /^[A-Za-z0-9._/-]+$/;

// Thrown to end the read with its verdict; main's caller prints it.
class Verdict {
  constructor(state, line, reason, cases) {
    this.rows = [["FILE", state, line, reason].join("\t")];
    for (const c of cases || []) {
      this.rows.push(["CASE", c.name, c.target, c.begin, c.end, "", ""].join("\t"));
    }
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
function scanCode(raw, stack) {
  const s = stack.map((e) => ({ ...e }));
  let i = 0;
  while (i < raw.length) {
    const top = s[s.length - 1];
    const ch = raw[i];
    const two = raw.slice(i, i + 2);
    if (top && top.kind === "comment") {
      if (two === "*/") {
        s.pop();
        i += 2;
      } else i += 1;
      continue;
    }
    if (top && top.kind === "template") {
      if (ch === "\\") i += 2;
      else if (ch === "`") {
        s.pop();
        i += 1;
      } else if (two === "${") {
        s.push({ kind: "expr", depth: 0 });
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
      i += 1;
      continue;
    }
    if (ch === "`") s.push({ kind: "template" });
    else if (top && ch === "{") top.depth += 1;
    else if (top && ch === "}") {
      if (top.depth === 0) s.pop();
      else top.depth -= 1;
    }
    i += 1;
  }
  return s;
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

function main(file) {
  const text = fs.readFileSync(file, "utf8");
  const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const lines = body.split(/\r?\n/);
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
      const [name, target] = readBegin(raw, lineNo);
      if (name === "") finish("malformed", lineNo, "grammar");
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

try {
  main(process.argv[2]);
} catch (err) {
  if (err instanceof Verdict) {
    process.stdout.write(err.rows.join("\n") + "\n");
  } else {
    process.stderr.write(`js-case-reader: cannot read ${process.argv[2]}: ${err.code || err.message}\n`);
    process.exitCode = 1;
  }
}
