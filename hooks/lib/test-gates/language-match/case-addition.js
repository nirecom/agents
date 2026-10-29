"use strict";
// The case-addition judgment (#2507 D7; ports bin/lib/test-language-match/case-addition.sh): when
// either version is not conforming, a case added there is caught by size instead of by target.
// caseAddition(head, file, match) -> the CASE_ADDED_WITHOUT_MARKERS line, or null. Units come
// from the case-count op, else both versions' code lines; a null head counts 0.

const R = require("../registry");
const P = require("../parts");
const S = require("../source");

const WHY = { 0: "no count in the answer", 1: "no case unit", 3: "no caseEmbedRules", 69: "runtime not installed", 70: "part unreachable" };

// codeLines(file, match) — lines neither blank nor starting (after leading blanks) with the prefix.
function codeLines(file, match) {
  if (!S.isFile(file)) return 0;
  const prefix = R.commentPrefix(match);
  const lines = S.textOf(file).split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines.filter((l) => {
    const t = l.replace(/\r$/, "").replace(/^\s+/, "");
    return t && !(prefix && t.startsWith(prefix));
  }).length;
}

// unitCount(entry, file) -> { count } or { why }.
function unitCount(entry, file) {
  let rc = 3;
  let out = "";
  if (R.fieldValue(entry, "caseEmbedRules.file")) {
    const r = P.embed(entry, "case-count", file);
    rc = r.rc;
    out = String(r.stdout || "");
  }
  out = out.replace(/\n+$/, "").replace(/\r$/, "");
  if (rc === 0 && /^[0-9]+$/.test(out)) return { count: Number.parseInt(out, 10) };
  return { why: WHY[rc] || `rc ${rc}` };
}

function caseAddition(head, file, match) {
  const m = R.match(match);
  if (!m) return null;
  let hOk = false;
  let hCount = 0;
  let why = "";
  if (!head) hOk = true;
  else {
    const h = unitCount(m.entry, head);
    if (h.why === undefined) {
      hCount = h.count;
      hOk = true;
    } else why = h.why;
  }
  const w = unitCount(m.entry, file);
  if (w.why !== undefined) {
    why = w.why;
    hOk = false;
  }
  let basis;
  if (hOk) {
    if (!(w.count > hCount)) return null;
    basis = `case units ${hCount} -> ${w.count}`;
  } else {
    const hLines = head ? codeLines(head, match) : 0;
    const wLines = codeLines(file, match);
    if (!(wLines > hLines)) return null;
    basis = `case count unavailable: ${why}; code lines ${hLines} -> ${wLines}`;
  }
  const marker = R.fieldValue(m.entry, "diagnostics.markerName") || "case markers";
  return `HIGH: ${match}: case added to a test file without valid case markers (${basis}); add ${marker} to every case first, then each case's target is checked code=CASE_ADDED_WITHOUT_MARKERS`;
}

module.exports = { caseAddition, codeLines, unitCount };
