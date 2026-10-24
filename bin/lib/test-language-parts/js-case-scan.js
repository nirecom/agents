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
const ESCAPE = /\\(?:x([0-9A-Fa-f]{2})|u([0-9A-Fa-f]{4})|u\{([0-9A-Fa-f]+)\}|([\s\S]?))/g;

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

// The literal's value, or null when it holds an escape other than a quote, a backslash, or one
// that evaluates to a TAB, CR or LF (`\t`, `\x09`, `\u000a`, `\u{d}` ...), which walk reads as grammar.
function constantValue(literal) {
  let constant = true;
  const value = literal.slice(1, -1).replace(ESCAPE, (all, hex2, hex4, hexN, ch) => {
    if (/[\\"'`]/.test(ch || "")) return ch;
    const code = ch ? { t: 9, r: 13, n: 10 }[ch] : parseInt(hex2 || hex4 || hexN, 16);
    if (code === 9 || code === 13 || code === 10) return String.fromCharCode(code);
    constant = false;
    return all;
  });
  return constant ? value : null;
}

function targetIsValid(target) {
  if (!TARGET_OK.test(target) || target.startsWith("/")) return false;
  const parts = target.split("/");
  return parts[0] !== "." && !parts.includes("..");
}

const REGEX_AFTER_WORD = new Set([
  "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await",
]);

const CONTROL_WORD = new Set(["if", "while", "for", "with"]);

// Whether a `/` after the line's significant code `sig` opens a regex (else it divides).
// A literal or template stands in `sig` as `"`, a whitespace run as one space; the previous
// line is not consulted. A `)` closing a control-statement paren is settled by scanCode instead.
function regexAllowed(sig) {
  const code = sig.trimEnd();
  const last = code[code.length - 1];
  if (last === undefined) return true;
  if (/[\w$]/.test(last)) return REGEX_AFTER_WORD.has(/[\w$]+$/.exec(code)[0]);
  return !/[)\]"]/.test(last);
}

// Whether a `(` after `sig` opens a control-statement paren: `if`, `while`, `for` or `with` as a
// word of its own, not a property such as `x.if`.
function opensControlParen(sig) {
  const m = /(\.\s*)?([\w$]+)$/.exec(sig.trimEnd());
  return Boolean(m) && !m[1] && CONTROL_WORD.has(m[2]);
}

// The index just past the regex literal (flags included) opened at `start`, or -1 when the line
// ends first: a regex never spans a line.
function regexEnd(raw, start) {
  let inClass = false;
  for (let i = start + 1; i < raw.length; i += 1) {
    const ch = raw[i];
    if (ch === "\\") i += 1;
    else if (ch === "[") inClass = true;
    else if (ch === "]") inClass = false;
    else if (ch === "/" && !inClass) {
      let j = i + 1;
      while (j < raw.length && /[A-Za-z]/.test(raw[j])) j += 1;
      return j;
    }
  }
  return -1;
}

// Walks one line and returns the region stack after it. Entries: { kind: "comment" },
// { kind: "template" }, { kind: "expr", depth } (inside `${`, depth = open inner `{`); empty = code.
// When `code` (an array) is given, the line's code characters are pushed onto it; comments,
// string, template and regex literal text become one space each; a quoted literal
// `keep(literal)` accepts is pushed as written. Within the line, a `/` right after the `)` of an
// `if`/`while`/`for`/`with` paren may open a regex; every other `)` (an unbalanced one too) divides.
function scanCode(raw, stack, code, keep) {
  const s = stack.map((e) => ({ ...e }));
  const out = code ? (t) => code.push(t) : () => {};
  let sig = "";
  const parens = [];
  let afterControlParen = false;
  const emit = (t, value) => {
    out(t);
    if (value) sig += '"';
    else if (t.trim()) sig += t;
    else if (sig && !sig.endsWith(" ")) sig += " ";
    if (value || t.trim()) afterControlParen = false;
  };
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
        emit(" ", true);
        i += 1;
      } else if (two === "${") {
        s.push({ kind: "expr", depth: 0 });
        emit(" ");
        sig += "{";
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
    if (ch === "/" && (afterControlParen || regexAllowed(sig))) {
      const end = regexEnd(raw, i);
      if (end !== -1) {
        emit(" ", true);
        i = end;
        continue;
      }
    }
    if (ch === '"' || ch === "'") {
      const start = i;
      i += 1;
      while (i < raw.length && raw[i] !== ch) i += raw[i] === "\\" ? 2 : 1;
      i += 1;
      const literal = raw.slice(start, i);
      emit(keep && keep(literal) ? literal : " ", true);
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
    const control = ch === "(" ? opensControlParen(sig) : false;
    if (ch !== "`") emit(ch);
    if (ch === "(") parens.push(control);
    else if (ch === ")" && parens.length) afterControlParen = parens.pop();
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

module.exports = { readLines, scanCode, scanLines };
