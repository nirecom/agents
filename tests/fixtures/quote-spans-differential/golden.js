"use strict";
// tests/fixtures/quote-spans-differential/golden.js
// Loads tests/fixtures/quote-spans-golden.jsonl and aligns it with the corpus.
//
// The frozen copies under tests/fixtures/quote-spans-frozen/ are the ORACLE the
// whole differential is measured against. Nothing in the suite used to check
// what they actually produce — only that they returned the right TYPES — so a
// truncated, hand-edited or accidentally-refactored frozen copy could redefine
// the baseline and the differential would stay green while comparing the new
// implementation against a corrupted "old" one.
//
// The golden file is a byte-level record of the pre-migration outputs, captured
// while the pre-refactor sources were still in the tree. Alignment is checked by
// INPUT, not by index, so inserting or reordering a corpus row is detected
// rather than silently shifting every expectation by one.

const fs = require("fs");

function loadGolden(goldenPath, cases) {
  if (!fs.existsSync(goldenPath)) {
    return { rows: null, problem: "golden file missing: " + goldenPath };
  }
  const rows = [];
  for (const raw of fs.readFileSync(goldenPath, "utf8").split(/\r?\n/)) {
    const t = raw.trim();
    if (!t || t.startsWith("#")) continue;
    rows.push(JSON.parse(t));
  }
  if (rows.length !== cases.length) {
    return {
      rows: null,
      problem: "golden/corpus size mismatch: corpus has " + cases.length +
               " cases, golden has " + rows.length + " rows",
    };
  }
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].in !== cases[i]) {
      return {
        rows: null,
        problem: "golden/corpus misalignment at row " + i + ": corpus " +
                 JSON.stringify(cases[i]) + " vs golden " + JSON.stringify(rows[i].in),
      };
    }
  }
  return { rows, problem: "" };
}

// Byte comparison of the frozen implementations against the golden record.
// Returns "" when every field matches, else the first mismatching field.
function frozenMismatch(g, out) {
  for (const k of ["huq", "sqa", "sdp", "fold"]) {
    if (out[k] !== g[k]) {
      return k + ": frozen produced " + JSON.stringify(out[k]) +
             " but the pre-migration golden is " + JSON.stringify(g[k]);
    }
  }
  return "";
}

module.exports = { loadGolden, frozenMismatch };
