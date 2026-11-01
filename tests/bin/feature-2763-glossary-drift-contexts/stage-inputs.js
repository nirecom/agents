"use strict";
// stage-inputs-intent-fields part of tests/bin/feature-2763-glossary-drift-contexts.js (#2763 S3-5).
// Holds no case markers; the entrypoint wraps run() in one.
// scanStageInputs builds term records from the intent rows: a V3 row's fields replace the glossary
// record's fields of the same term, and a delete row is decided by record.term.
// Rows: [name, glossaryTerms, intentRows, [[term, variant]]], over two code comment lines.

const ADH = "allow-deny hook";
// Line 3 drifts whenever the term is live, so a record the scan silently drops cannot pass a row.
const TEXT = `"use strict";\n// a mid-line allow-deny-hook here\n// the Allow-deny hook here\nmodule.exports = 1;\n`;
const LIVE = [ADH, "Allow-deny hook"];
const rec = (identifiers) => ({ term: ADH, identifiers, homographs: [] });
const row = (operation, identifiers) => (identifiers === undefined
  ? { term: ADH, category: "internal", operation, definition: "A hook." }
  : { term: ADH, category: "internal", operation, definition: operation === "delete" ? "" : "A hook.", identifiers, homographs: [] });

const ROWS = [
  ["string term, nothing declared (baseline)", [ADH], [], [[ADH, "allow-deny-hook"], LIVE]],
  ["glossary Identifier declared, no intent row (control)", [rec(["allow-deny-hook"])], [], [LIVE]],
  ["V3 row with an empty Identifier replaces the glossary field", [rec(["allow-deny-hook"])], [row("redefine", [])], [[ADH, "allow-deny-hook"], LIVE]],
  ["V3 row declares an Identifier the glossary lacks", [rec([])], [row("redefine", ["allow-deny-hook"])], [LIVE]],
  ["V2 row leaves the glossary field in place", [rec(["allow-deny-hook"])], [row("redefine")], [LIVE]],
  ["V3 delete row removes a term held as a record", [rec(["allow-deny-hook"]), "workflow step"], [row("delete", [])], []],
];

function run(F) {
  const drift = F.mod("bin/lib/glossary-drift.js");
  if (!drift) return;
  if (!F.check("bin/lib/glossary-drift.js exports scanStageInputs", typeof drift.scanStageInputs === "function",
    Object.keys(drift).join(","))) return;
  for (const [name, terms, rows, want] of ROWS) {
    let got;
    try {
      got = drift.scanStageInputs({
        glossary: { terms },
        intentRows: { rows },
        artifact: { files: [{ path: "tests/x.js", kind: "code", text: TEXT }] },
      }).map((h) => [h.term, h.variant]);
    } catch (e) {
      got = `threw ${e && e.message}`;
    }
    F.check(`scanStageInputs ${name}: -> ${JSON.stringify(want)}`, JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  }
}

module.exports = { run };
