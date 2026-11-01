"use strict";
// long-run-linear-time and identifier-ranges-oracle parts of
// tests/bin/feature-2763-glossary-drift-contexts.js (#2763 S1).
// Holds no case markers; the entrypoint wraps run() / runOracle() in one each.
// run(): one findDrift call over a 100,000-character input must finish under LIMIT_MS. The old
// identifierRanges regex rescans the rest of a whitespace-free run from every start position, so
// a long run without a symbol is quadratic (measured before the fix: (a) and (d) take many seconds).
// runOracle(): the linear identifierRanges must return exactly the ranges the old regex returned.

const LIMIT_MS = 2000;
const N = 100000;
const OLD_IDENT_CHUNK_RE = /\S*[_=${}]\S*/g;
const code = (comment) => `"use strict";\n${comment}\nmodule.exports = 1;\n`;

const INPUTS = [
  ["(a) one run of letters", "markdown", "a".repeat(N)],
  ["(b) short identifier chunks", "markdown", "a_b ".repeat(N / 4)],
  ["(c) ordinary prose words", "markdown", "the cat ".repeat(N / 8)],
  ["(d) one run of letters in a code comment", "code", code(`// ${"a".repeat(N)}`)],
];

const ms = (start) => {
  const [s, ns] = process.hrtime(start);
  return s * 1000 + ns / 1e6;
};

function run(F) {
  const drift = F.mod("bin/lib/glossary-drift.js");
  if (!drift) return;
  if (!F.check("bin/lib/glossary-drift.js exports findDrift", typeof drift.findDrift === "function",
    Object.keys(drift).join(","))) return;
  for (const [name, format, text] of INPUTS) {
    const start = process.hrtime();
    let error = "";
    try {
      drift.findDrift(text, format, ["allow-deny hook", "AGENTS_MAIN_ROOT", "workflow step"]);
    } catch (e) {
      error = `threw ${e && e.message}`;
    }
    const took = ms(start);
    F.check(`long-run ${name}: findDrift over ${text.length} chars < ${LIMIT_MS} ms`,
      error === "" && took < LIMIT_MS, error || `${Math.round(took)} ms`);
  }
}

function oldRanges(line) {
  if (/^\s*(?:#{1,6}\s+)?Tags:/.test(line)) return [[0, line.length]];
  const out = [];
  let m;
  OLD_IDENT_CHUNK_RE.lastIndex = 0;
  while ((m = OLD_IDENT_CHUNK_RE.exec(line)) !== null) out.push([m.index, m.index + m[0].length]);
  return out;
}

const ORACLE_LINES = [
  ["symbol at the start", "_abc def"],
  ["symbol at the end", "abc def_"],
  ["symbol in the middle", "abc d_ef ghi"],
  ["brace expansion", "the {A,B} pair"],
  ["dollar variable", "read $x here"],
  ["assignment", "when a=b holds"],
  ["tabs around a chunk", "a\tx_y\tb"],
  ["leading and trailing spaces", "   x_y   "],
  ["empty line", ""],
  ["only spaces", "    "],
  ["no symbol", "plain words only"],
  ["several chunks", "A_B c=d {e} $f g"],
  ["adjacent symbols", "__ == $$ {}"],
  ["Tags line", "// Tags: TL2, allow-deny-hook"],
  ["markdown Tags heading", "# Tags: allow-deny-hook"],
  ["long run then a chunk", `${"a".repeat(500)} x_y`],
];

function runOracle(F) {
  const context = F.mod("bin/lib/glossary-drift/context.js");
  if (!context) return;
  if (!F.check("context.js exports identifierRanges", typeof context.identifierRanges === "function",
    Object.keys(context).join(","))) return;
  for (const [name, line] of ORACLE_LINES) {
    const want = oldRanges(line);
    let got;
    try {
      got = context.identifierRanges(line);
    } catch (e) {
      got = `threw ${e && e.message}`;
    }
    F.check(`identifierRanges oracle ${name}: ${JSON.stringify(line)} -> ${JSON.stringify(want)}`,
      JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  }
}

module.exports = { run, runOracle };
