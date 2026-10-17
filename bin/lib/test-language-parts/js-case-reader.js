"use strict";
// bin/lib/test-language-parts/js-case-reader.js <file> — the js entry's case reader child.
// A line reader, not a parser: it reports the column-0 `caseBegin("<name>", "<target>");` ...
// `caseEnd();` pairs of tests/lib/harness.js and never runs or parses the file. Prints
//   FILE\t<state>\t<line>\t<reason>   and, when conforming, one
//   CASE\t<idx>\t<name>\t<target>\t<begin>\t<end>\t\t   per pair.
// A call-looking line inside a block comment or a multi-line template string cannot be
// settled by reading lines, so the file is reported as `uncertain`. Exit 1: unreadable file.

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
    for (const [i, c] of (cases || []).entries()) {
      this.rows.push(["CASE", i, c.name, c.target, c.begin, c.end, "", ""].join("\t"));
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

// The line with its one-line string literals and its trailing line comment removed.
function withoutLiterals(text) {
  return text.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""').replace(/\/\/.*$/, "");
}

function oddBackticks(text) {
  return (text.replace(/\\./g, "").match(/`/g) || []).length % 2 === 1;
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
  let region = "";
  for (const [i, raw] of lines.entries()) {
    const lineNo = i + 1;
    if (region) {
      if (CALL_LOOKING.test(raw)) finish("uncertain", lineNo, "grammar");
      if (region === "comment" ? raw.includes("*/") : oddBackticks(raw)) region = "";
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
    const bare = withoutLiterals(raw);
    const opened = bare.lastIndexOf("/*");
    if (opened !== -1 && !bare.slice(opened + 2).includes("*/")) region = "comment";
    else if (oddBackticks(bare)) region = "template";
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
