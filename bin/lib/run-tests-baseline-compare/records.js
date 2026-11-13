// bin/lib/run-tests-baseline-compare/records.js — reads one result dir (cases.tsv, fail-details.tsv)
// and the rename map into the line form the comparer works on: per case, its detail lines.
"use strict";

const fs = require("node:fs");
const path = require("node:path");

function readRows(file) {
  let text;
  try { text = fs.readFileSync(file, "utf8"); } catch { return []; }
  return text.split(/\r?\n/).filter((l) => l !== "").map((l) => l.split("\t"));
}

// readSide(dir) — { recorded, hasRecords, failCases: Set, seenCases: Set, lines: [[case, detail]] }.
// recorded: any case or detail record at all (the fp header); hasRecords: a FAIL case or a detail.
// A FAIL case is a seq whose last cases.tsv record is FAIL; one without a detail line gives "".
function readSide(dir) {
  const caseRows = readRows(path.join(dir, "cases.tsv")).filter((r) => r.length >= 3);
  const detailRows = readRows(path.join(dir, "fail-details.tsv")).filter((r) => r.length >= 3);
  const last = new Map();
  for (const [seq, state, name] of caseRows) last.set(seq, { state, name });
  // A case still OPEN at the end was cut off mid-way: it was reached but never settled.
  const seenCases = new Set();
  for (const { state, name } of last.values()) if (state !== "OPEN") seenCases.add(name);
  const failCases = new Set();
  const detailSeqs = new Set(detailRows.map((r) => r[0]));
  const lines = detailRows.map(([, name, ...text]) => [name, text.join("\t")]);
  for (const [seq, { state, name }] of last) {
    if (state !== "FAIL") continue;
    failCases.add(name);
    if (!detailSeqs.has(seq)) lines.push([name, ""]);
  }
  return {
    recorded: caseRows.length + detailRows.length > 0,
    hasRecords: lines.length > 0,
    failCases,
    seenCases,
    lines,
  };
}

// readRenameMap(file) — [[old, new]] from `<old>\t<new>` rows (rtb_rename_pairs output).
function readRenameMap(file) {
  if (!file) return [];
  return readRows(file).filter((r) => r.length >= 2 && r[0] && r[1]).map((r) => [r[0], r[1]]);
}

module.exports = { readSide, readRenameMap };
