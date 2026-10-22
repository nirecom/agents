"use strict";
// T7-3 (input 3, intent_rows): adding, deleting, or changing the term / category / operation /
// definition of a row in intent.md ## Glossary (a case-only term change included) stales the record for all six stages (for the
// intent stage the row lives in the artifact range too, so artifact moves with it). An edit
// outside ## Glossary never moves intent_rows. provenanceFingerprint binds the approval sha.

const F = require("../../lib/glossary-check-fixture");
const C = require("./common");

const HEAD = "## Glossary\n\n| Term | Category | Operation | Definition |\n|---|---|---|---|\n";
const BASE_ROW = ["fixture term", "session", "add", "A term of the fixture session."];

function intentBody(stage, rows, goal) {
  const word = stage === "intent" ? F.VARIANT : F.TERM;
  const g = goal || `Each ${word} is checked.`;
  return `# Intent\n\n## Goal\n\n${g}\n\n## Issues\n\n- #1 fixture\n\n${HEAD}` +
    rows.map((r) => `| ${r.join(" | ")} |\n`).join("");
}

function rowMutations() {
  return [
    ["an added row", (rows) => rows.concat([["second term", "internal", "add", "Another fixture term."]])],
    ["a deleted row", (rows) => rows.slice(0, 1)],
    ["a changed term", (rows) => [["fixture terms"].concat(rows[0].slice(1))]],
    ["a changed category", (rows) => [[rows[0][0], "internal", rows[0][2], rows[0][3]]]],
    ["a changed operation", (rows) => [[rows[0][0], rows[0][1], "redefine", rows[0][3]]]],
    ["a changed definition", (rows) => [[rows[0][0], rows[0][1], rows[0][2], "A term of the fixture sessions."]]],
    // A case-only change of the session term: the drift scan treats the exact spelling as the
    // non-variant form, so it changes the scan result and must stale the record.
    ["a case-only term change", (rows) => [[rows[0][0].charAt(0).toUpperCase() + rows[0][0].slice(1)].concat(rows[0].slice(1))]],
  ];
}

function rows(m, stages = F.STAGES) {
  for (const stage of stages) {
    const ctx = C.baseline(m, `t73-${stage}`, stage);
    const want = stage === "intent" ? ["artifact", "intent_rows"] : "intent_rows";
    let cur = [BASE_ROW];
    for (const [label, next] of rowMutations()) {
      C.cycle(m, ctx, `intent ## Glossary: ${label}`, want, () => {
        cur = next(cur);
        F.writePlan(ctx.sid, "intent", intentBody(stage, cur));
      });
    }
    const outside = () => F.writePlan(ctx.sid, "intent", intentBody(stage, cur, `Each ${F.VARIANT} goal is reworded.`));
    if (stage === "intent") C.cycle(m, ctx, "an intent edit outside ## Glossary", "artifact", outside);
    else C.unchanged(m, ctx, "an intent edit outside ## Glossary", outside);
  }
}

function provenance(m) {
  const ops = F.sha256("fixture ops");
  const a = m.scope.provenanceFingerprint({ ops, approvalSha: "a".repeat(64) });
  const b = m.scope.provenanceFingerprint({ ops, approvalSha: "b".repeat(64) });
  F.check("provenanceFingerprint: inputs.intent_rows is the approval sha",
    !!a && a.inputs && a.inputs.intent_rows === "a".repeat(64), JSON.stringify(a));
  F.check("provenanceFingerprint: a new approval sha (CONFIRM_INTENT re-taken) moves the fingerprint",
    !!a && !!b && /^[0-9a-f]{64}$/.test(a.fingerprint || "") && a.fingerprint !== b.fingerprint, JSON.stringify({ a, b }));
  F.check("provenanceFingerprint: ops and rules do not move with the approval sha",
    !!a && !!b && a.inputs.ops === b.inputs.ops && a.inputs.rules === b.inputs.rules, JSON.stringify({ a, b }));
}

// Section entry points, so entry files can split the sections across processes.
const runRows = C.withModules(rows);
const runProvenance = C.withModules(provenance);

function run() {
  runRows();
  runProvenance();
}

module.exports = { run, runRows, runProvenance };
