"use strict";
// bin/lib/test-language-parts/js-case-analyzer.js <op> <file> [args] — the js entry's caseEmbedRules
// analyzer child. Reads the file with the line scan of js-case-scan.js (never runs it) and prints:
//   deps           ORDER\t<idx>\t<begin>\t<end> per case, then <idx>\t<csv> per case
//   leftover-defs  <line>\t<name> per top-level function no other line names
//   self-impl <file> <helper>  <line>\t<kind>\t<detail> per top-level counter-init / harness-redef
//   skip-reason    custom-runner when the file does not require node:test; else nothing
//   syntax-check   nothing; exit 0 when `node --check` accepts the file, 1 with its reason otherwise
//   case-count     nothing; exit 1 for every file: js has no case unit apart from its markers
// Exit 1: unreadable, a syntax error, not conforming (deps) or no unit (case-count); 2: unknown op.
// The analysis is an approximation: top-level means column 0 outside every case and region.

const fs = require("fs");
const { spawnSync } = require("child_process");
const { readLines, scanCode, scanLines } = require("./js-case-scan");

const DECL = /^(?:(?:async\s+)?function\s*\*?\s*|(?:const|let|var)\s+|class\s+)([A-Za-z_$][\w$]*)/;
const FUNC_VALUE = /^(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)/;
const IDENT = /[A-Za-z_$][\w$]*/g;
const COUNTER = /^(?:let|var)\s+(PASS|FAIL|passed|failed)\s*=\s*0\s*(?:;|$)/;
const EXPORTS = /module\.exports\s*=\s*\{([^}]*)\}/;
const NODE_TEST = /\b(?:require\s*\(|from\s+|import\s*\()\s*["']node:test["']/;
const NODE_TEST_LITERAL = /^["']node:test["']$/;

// The file's code lines (1-based; comments and string text blanked) and its column-0
// declarations outside every case: { name, line, func }.
function survey(lines, cases) {
  const inCase = (n) => cases.some((c) => n >= c.begin && n <= c.end);
  const code = [""];
  const defs = [];
  let stack = [];
  for (const [i, raw] of lines.entries()) {
    const out = [];
    const atTop = stack.length === 0;
    stack = scanCode(raw, stack, out);
    code.push(out.join(""));
    const m = atTop && !inCase(i + 1) ? DECL.exec(raw) : null;
    if (m) defs.push({ name: m[1], line: i + 1, func: !/^(?:const|let|var)\s/.test(raw) || FUNC_VALUE.test(raw) });
  }
  return { code, defs };
}

// The identifiers a code line names, a property access (`.name`) excluded.
function names(text) {
  const found = [];
  for (const m of text.matchAll(IDENT)) {
    if (text[m.index - 1] !== ".") found.push(m[0]);
  }
  return found;
}

function conforming(lines) {
  const v = scanLines(lines);
  if (v.state !== "conforming") throw new Error(`the file is ${v.state}, not conforming`);
  return v.cases;
}

function deps(lines) {
  const cases = conforming(lines);
  const { code, defs } = survey(lines, cases);
  const rows = cases.map((c, i) => `ORDER\t${i}\t${c.begin}\t${c.end}`);
  cases.forEach((c, i) => {
    const used = new Set();
    for (let n = c.begin + 1; n < c.end; n += 1) for (const x of names(code[n])) used.add(x);
    rows.push(`${i}\t${defs.filter((d) => used.has(d.name)).map((d) => d.name).join(",")}`);
  });
  return rows;
}

function leftoverDefs(lines) {
  const v = scanLines(lines);
  const { code, defs } = survey(lines, v.cases);
  return defs
    .filter((d) => d.func)
    .filter((d) => !code.some((text, n) => {
      const found = names(text);
      // The declaration's own line names it once; another mention there is a use.
      return found.filter((x) => x === d.name).length > (n === d.line ? 1 : 0);
    }))
    .map((d) => `${d.line}\t${d.name}`);
}

// The names the helper library exports (`module.exports = { a, b: c }` keys); none when unreadable.
function helperNames(helper) {
  let text = "";
  try {
    text = helper ? fs.readFileSync(helper, "utf8") : "";
  } catch {
    return new Set();
  }
  const m = EXPORTS.exec(text);
  if (!m) return new Set();
  return new Set(m[1].split(",").map((s) => s.split(":")[0].trim()).filter((s) => /^[A-Za-z_$][\w$]*$/.test(s)));
}

function selfImpl(lines, helper) {
  const { defs } = survey(lines, scanLines(lines).cases);
  const own = helperNames(helper);
  const rows = [];
  for (const d of defs) {
    const c = COUNTER.exec(lines[d.line - 1]);
    if (c) rows.push({ line: d.line, text: `${d.line}\tcounter-init\t${c[1]}=0` });
    if (own.has(d.name)) rows.push({ line: d.line, text: `${d.line}\tharness-redef\t${d.name}` });
  }
  return rows.sort((a, b) => a.line - b.line).map((r) => r.text);
}

// custom-runner: without node:test the wrapper runs the file as a plain script, so the cases
// are the file's own loop and the per-case reporter sees none of them. Only the code region
// decides: a comment, string or template that names node:test is blanked, and only a real
// "node:test" literal survives the scan for NODE_TEST to match.
function skipReason(lines) {
  const code = [];
  let stack = [];
  for (const raw of lines) {
    stack = scanCode(raw, stack, code, (literal) => NODE_TEST_LITERAL.test(literal));
    code.push("\n");
  }
  return NODE_TEST.test(code.join("")) ? [] : ["custom-runner"];
}

// node --check parses the file without running it; its stderr is the reason.
function syntaxCheck(file) {
  const done = spawnSync(process.execPath, ["--check", file], { encoding: "utf8" });
  if (done.status === 0) return [];
  throw new Error((done.stderr || done.error?.message || `node --check exited ${done.status}`).trim());
}

function caseCount() {
  throw new Error("no case unit");
}

const OPS = {
  "case-count": caseCount,
  deps,
  "leftover-defs": leftoverDefs,
  "self-impl": selfImpl,
  "skip-reason": skipReason,
  "syntax-check": (lines, helper, file) => syntaxCheck(file),
};

function main(argv) {
  const [op, file, helper] = argv;
  if (!Object.hasOwn(OPS, op || "")) {
    process.stderr.write(`[js-case-analyzer] unknown op: ${op || ""}\n`);
    return 2;
  }
  let lines;
  try {
    lines = readLines(file);
  } catch (err) {
    process.stderr.write(`js-case-analyzer: cannot read ${file}: ${err.code || err.message}\n`);
    return 1;
  }
  try {
    const rows = OPS[op](lines, helper, file);
    if (rows.length) process.stdout.write(rows.join("\n") + "\n");
    return 0;
  } catch (err) {
    process.stderr.write(`js-case-analyzer: ${op} ${file}: ${err.message}\n`);
    return 1;
  }
}

process.exitCode = main(process.argv.slice(2));
