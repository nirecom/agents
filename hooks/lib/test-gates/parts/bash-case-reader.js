"use strict";
// The bash entry's caseMarkerReader (#2507 D7; ports trp_parse_case_markers of
// bin/lib/test-retire-predicate/case-parser.sh, which stays for the bash callers).
// read(file) -> { rc: 0, g }: the case-marker globals of reader-records.js. Never runs the file.

const { fileLines, scanLine, heredocTerm, heredocEnds } = require("./bash-scan");
const { emptyGlobals, targetValid } = require("./reader-records");
const { endOwnsLine } = require("./bash-case-reader/end-owns-line");
const { depthStep } = require("./bash-case-reader/depth");

const RE_CAND = /(^|[^A-Za-z0-9_])case_(begin|end)([^A-Za-z0-9_]|$)/;
const RE_BEGIN = /^case_begin[ \t\n\v\f\r]+"([^"$`\\]*)"[ \t\n\v\f\r]+"([^"$`\\]*)"([ \t\n\v\f\r]*\|\|[ \t\n\v\f\r]*true)?[ \t\n\v\f\r]*$/;
const RE_END = /^case_end([ \t\n\v\f\r].*)?$/s;

function fail(g, line, reason) {
  return { ...g, malformed: true, line: String(line), reason };
}

// The marker lines in order, or a failed g. A candidate line never changes the depth.
function scan(lines) {
  let g = emptyGlobals();
  const marks = [];
  let depth = 0;
  let quoteRisk = false;
  let hd = null;
  for (const [i, line] of lines.entries()) {
    const lineno = i + 1;
    if (hd) {
      if (heredocEnds(line, hd)) hd = null;
      continue;
    }
    hd = heredocTerm(line) || null;
    if (RE_CAND.test(line)) {
      g.hasMarkers = true;
      const b = RE_BEGIN.exec(line);
      if (b) {
        if (depth !== 0) return { g: { ...fail(g, lineno, "depth"), uncertain: quoteRisk } };
        if (!/[\t\r]/.test(b[2]) && !targetValid(b[2])) return { g: fail(g, lineno, "target") };
        marks.push({ kind: "begin", name: b[1], target: b[2], line: lineno });
      } else if (RE_END.test(line) && endOwnsLine(line)) {
        if (depth !== 0) return { g: { ...fail(g, lineno, "depth"), uncertain: quoteRisk } };
        marks.push({ kind: "end", line: lineno });
      } else return { g: fail(g, lineno, "grammar") };
      continue;
    }
    const s = scanLine(line);
    if (s.open) quoteRisk = true;
    depth = depthStep(s.code, depth);
  }
  return { g, marks, last: lines.length };
}

// read(file) — the bash reader's verdict for the file; a missing file has no markers.
function read(file) {
  const lines = fileLines(file);
  if (lines === null) return { rc: 0, g: emptyGlobals() };
  const r = scan(lines);
  if (!r.marks || !r.g.hasMarkers) return { rc: 0, g: r.g };
  const { marks } = r;
  const balanced = marks.length % 2 === 0 && marks.every((m, i) => m.kind === (i % 2 === 0 ? "begin" : "end"));
  if (!balanced) return { rc: 0, g: fail(r.g, r.last, "balance") };
  const cases = [];
  for (let i = 0; i < marks.length; i += 2) {
    cases.push({ name: marks[i].name, target: marks[i].target, begin: String(marks[i].line), end: String(marks[i + 1].line) });
  }
  return { rc: 0, g: { ...r.g, cases } };
}

module.exports = { read };
