"use strict";
// Interpreter for the decide table: input validation, feature extraction, matching rows' when, output template expansion.
// The row data in rows.js owns the decisions themselves; this file holds none.
// when is { anyOf: [conj, ...] }; conj maps feature name -> { in: [...] } | { notIn: [...] }.

const DECIDE_INPUT_KEYS = Object.freeze(["branchResult", "baseResult", "testFileChange", "caseComparison"]);
const TFC_VALUES = Object.freeze(["changed", "unchanged", "unknown"]);
const CMP_FIELDS = Object.freeze(["branchRecordsAsNormal", "branchRecordsAsInterrupted", "branchRecordsIgnored"]);
const CMP_VALUES = Object.freeze(["same", "new", "no-records", "branch-missing", "base-missing", "compare-failed"]);
const RESULT_KEYS = ["verdict", "termination", "exitCode", "hitKind"];

function checkResult(r, name) {
  if (!r || typeof r !== "object") throw new Error(`decide: ${name} must be an object`);
  for (const k of RESULT_KEYS) if (!(k in r)) throw new Error(`decide: ${name}.${k} is missing`);
  if (r.termination !== "launcher-setup-failed" && !Number.isInteger(r.exitCode)) {
    throw new Error(`decide: ${name}.exitCode must be an integer: ${JSON.stringify(r.exitCode)}`);
  }
}

function checkInput(input) {
  if (!input || typeof input !== "object") throw new Error("decide: input must be an object");
  const keys = Object.keys(input).sort();
  if (keys.join(",") !== [...DECIDE_INPUT_KEYS].sort().join(",")) {
    throw new Error(`decide: input keys must be exactly ${DECIDE_INPUT_KEYS.join(", ")}: got ${keys.join(", ")}`);
  }
  checkResult(input.branchResult, "branchResult");
  if (input.baseResult !== null) checkResult(input.baseResult, "baseResult");
  if (!TFC_VALUES.includes(input.testFileChange)) throw new Error(`decide: testFileChange: ${JSON.stringify(input.testFileChange)}`);
  const c = input.caseComparison;
  if (!c || typeof c !== "object") throw new Error("decide: caseComparison must be an object");
  for (const f of CMP_FIELDS) if (!CMP_VALUES.includes(c[f])) throw new Error(`decide: caseComparison.${f}: ${JSON.stringify(c[f])}`);
}

// Features: 4 per comparison side result, baseResult presence, test file change status, 3 case comparison fields.
function features(input) {
  const i = input || {};
  const f = {};
  const side = (name, r) => { for (const k of RESULT_KEYS) f[`${name}.${k}`] = r && typeof r === "object" ? r[k] : null; };
  side("branchResult", i.branchResult);
  f.baseResult = i.baseResult === null ? "absent" : "present";
  side("baseResult", i.baseResult);
  f.testFileChange = i.testFileChange;
  for (const k of CMP_FIELDS) f[`caseComparison.${k}`] = i.caseComparison ? i.caseComparison[k] : undefined;
  return f;
}

const condHolds = (c, v) => (Array.isArray(c.in) ? c.in.includes(v) : !c.notIn.includes(v));
const conjHolds = (conj, f) => Object.keys(conj).every((k) => condHolds(conj[k], f[k]));
const rowHolds = (row, f) => row.when.anyOf.some((conj) => conjHolds(conj, f));

// Returns every row whose when matches input (pure function).
const matchDecideRows = (rows, input) => matchFeatures(rows, features(input));
const matchFeatures = (rows, f) => rows.filter((r) => rowHolds(r, f));

// Replaces {feature name} in detail with the input value. A special output without class is returned as is.
function render(output, f) {
  if (output.class === undefined) return Object.assign({}, output);
  return { class: output.class, detail: output.detail.replace(/\{([^}]+)\}/g, (_, k) => String(f[k])) };
}

function evaluate(rows, input) {
  checkInput(input);
  const f = features(input);
  const hits = matchFeatures(rows, f);
  if (hits.length !== 1) {
    throw new Error(`decide: exactly one row must match, got ${hits.length} (${hits.map((r) => r.id).join(", ")}): ${JSON.stringify(input)}`);
  }
  const row = hits[0];
  return { rowId: row.id, output: render(row.output, f), fieldRead: row.fieldRead || null };
}

module.exports = { evaluate, matchDecideRows, DECIDE_INPUT_KEYS, TFC_VALUES, CMP_FIELDS, CMP_VALUES };
