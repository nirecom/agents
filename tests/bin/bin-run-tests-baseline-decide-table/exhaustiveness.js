"use strict";
// Private cases of tests/bin/bin-run-tests-baseline-decide-table.js: exhaustiveness.
// Every input of the domain the module enumerates matches exactly one row, that domain covers the image of
// the RTB_EXEC_* domain this test declares itself through the parser, and the shape of the table rows.
// Apart from the module's enumeration, also checks exactly one row on the product parser image x (parser image ∪ null).
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { caseBegin, caseEnd } = require("../../lib/harness");
const S = require("./_shared");

caseBegin("DT-exhaustive-module-domain", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-exhaustive: every input of enumerateDecideInputDomain matches exactly one row", () => {
  const domain = Array.from(S.D().enumerateDecideInputDomain());
  assert.ok(domain.length > 0, "the domain is not empty");
  const rowIds = new Set(S.D().DECIDE_ROWS.map((r) => r.id));
  for (const input of domain) {
    const label = JSON.stringify(input);
    S.decideOne(input, label);
    for (const row of S.D().listMatchingDecideRows(input)) assert.ok(rowIds.has(row.id), `${label}: row ${row.id} is in DECIDE_ROWS`);
  }
});
caseEnd();

caseBegin("DT-exhaustive-domain-covers-parser-image", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-domain-cover: the input domain covers the parser image on both the branch side and the merge base side, and the other inputs hold every value", () => {
  const image = S.parserImage();
  assert.ok(image.length > 0, "the parser image is not empty");
  const csr = new Set(Array.from(S.D().enumerateComparisonSideResultDomain()).map(S.key));
  for (const r of image) assert.ok(csr.has(S.key(r)), `the comparison side result domain contains ${S.key(r)}`);
  const seen = { branch: new Set(), base: new Set(), tfc: new Set() };
  const cmpSeen = Object.fromEntries(S.CMP_FIELDS.map((f) => [f, new Set()]));
  for (const input of S.D().enumerateDecideInputDomain()) {
    seen.branch.add(S.key(input.branchResult));
    seen.base.add(S.key(input.baseResult));
    seen.tfc.add(input.testFileChange);
    for (const f of S.CMP_FIELDS) cmpSeen[f].add(input.caseComparison[f]);
  }
  for (const r of image) {
    assert.ok(seen.branch.has(S.key(r)), `${S.key(r)} appears in branchResult`);
    assert.ok(seen.base.has(S.key(r)), `${S.key(r)} appears in baseResult`);
  }
  assert.ok(seen.base.has("null"), "null appears in baseResult");
  assert.deepEqual([...seen.tfc].sort(), [...S.TFC].sort(), "the 3 values of testFileChange");
  for (const f of S.CMP_FIELDS) assert.deepEqual([...cmpSeen[f]].sort(), [...S.CMP_VALUES].sort(), `the 6 values of ${f}`);
});
caseEnd();

caseBegin("DT-exhaustive-independent-product", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-product: on the product parser image x (parser image ∪ null), exactly one row and a valid output shape", () => {
  const image = S.parserImage();
  for (const br of image) {
    for (const base of [null, ...image]) {
      S.decideOne(S.IN(br, base), `branch=${S.key(br)} base=${S.key(base)}`);
    }
  }
  // The product of case comparison and file change runs over the branch representatives that enter table 1 x base FAIL.
  const reps = [S.K.failNormal, S.K.fail124, S.K.skip, S.K.unsupported, S.K.unrunnable, S.K.timeout,
    Object.assign({}, S.K.failNormal, { hitKind: "root-decoy-or-worktree-change" })];
  for (const br of reps) {
    for (const tfc of S.TFC) {
      for (const a of S.CMP_VALUES) for (const b of S.CMP_VALUES) for (const c of S.CMP_VALUES) {
        const cmp = { branchRecordsAsNormal: a, branchRecordsAsInterrupted: b, branchRecordsIgnored: c };
        S.decideOne(S.IN(br, S.K.failNormal, tfc, cmp), `branch=${S.key(br)} tfc=${tfc} cmp=${a}/${b}/${c}`);
      }
    }
  }
});
caseEnd();

caseBegin("DT-rows-shape", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-rows-shape: row ids are unique, groups are i-iv, discrepancyId points at a record id", () => {
  const D = S.D();
  const rows = D.DECIDE_ROWS;
  assert.ok(Array.isArray(rows) && rows.length > 0, "DECIDE_ROWS is a non-empty array");
  const ids = rows.map((r) => r.id);
  assert.equal(new Set(ids).size, ids.length, "row ids are unique");
  const recIds = new Set(D.RECORDED_DISCREPANCIES.map((d) => d.id));
  for (const r of rows) {
    assert.ok(typeof r.id === "string" && r.id.length > 0, `row ${JSON.stringify(r.id)}: id is a string`);
    assert.ok(["i", "ii", "iii", "iv"].includes(r.group), `row ${r.id}: group=${r.group}`);
    if (r.discrepancyId !== undefined) assert.ok(recIds.has(r.discrepancyId), `row ${r.id}: discrepancyId=${r.discrepancyId} is recorded`);
  }
  for (const g of ["i", "ii", "iii", "iv"]) assert.ok(rows.some((r) => r.group === g), `group ${g} has rows`);
  // The intended discrepancies whose reading differs by comparison side (1, 2, 5) are referenced from rows.
  for (const n of [1, 2, 5]) {
    const rec = D.RECORDED_DISCREPANCIES.find((d) => d.discrepancyNumber === n);
    assert.ok(rec && rows.some((r) => r.discrepancyId === rec.id), `a row references discrepancy ${n}`);
  }
});
caseEnd();

const rowIds = (rows) => rows.map((r) => r.id);
const roundTrip = (v) => JSON.parse(JSON.stringify(v));
// Returns the first place holding a function, RegExp, undefined or non-plain object (null for plain data).
function nonData(v, at) {
  if (v === null || ["string", "number", "boolean"].includes(typeof v)) return null;
  if (Array.isArray(v)) {
    for (let i = 0; i < v.length; i++) { const p = nonData(v[i], `${at}[${i}]`); if (p) return p; }
    return null;
  }
  if (typeof v !== "object" || Object.getPrototypeOf(v) !== Object.prototype) return `${at} (${typeof v})`;
  for (const [k, x] of Object.entries(v)) { const p = nonData(x, `${at}.${k}`); if (p) return p; }
  return null;
}
// The module domain does not contain a decoy branch x a changed test file, so add those representatives.
function* witnessSources() {
  yield* S.D().enumerateDecideInputDomain();
  const decoy = Object.assign({}, S.K.failNormal, { hitKind: "root-decoy-or-worktree-change" });
  for (const tfc of S.TFC) yield S.IN(decoy, S.K.failNormal, tfc);
}
let witnessCache;
// Row id → one input that row matches (picked up through explainDecision's rowId).
function witnesses() {
  if (!witnessCache) {
    witnessCache = new Map();
    for (const input of witnessSources()) {
      const id = S.D().explainDecision(input).rowId;
      if (!witnessCache.has(id)) witnessCache.set(id, input);
    }
  }
  return witnessCache;
}

caseBegin("DT-rows-data", "bin/lib/run-tests-baseline-decide/rows.js");
test("DT-rows-data: each row holds its condition when and its output as plain data, unchanged by a JSON round trip", () => {
  const D = S.D();
  for (const r of D.DECIDE_ROWS) {
    for (const k of ["when", "output"]) {
      assert.ok(r[k] !== null && typeof r[k] === "object", `row ${r.id}: ${k} is an object (actual ${typeof r[k]})`);
      assert.equal(nonData(r[k], k), null, `row ${r.id}: ${k} is plain data`);
      assert.deepEqual(roundTrip(r[k]), r[k], `row ${r.id}: ${k} is unchanged by a JSON round trip`);
    }
  }
  const copied = roundTrip(D.DECIDE_ROWS);
  for (const [id, input] of witnesses()) {
    assert.deepEqual(rowIds(D.matchDecideRows(copied, input)), [id], `even on the JSON round-tripped table, only ${id} matches the input of ${id}`);
  }
});
caseEnd();

caseBegin("DT-rows-overlap-detected", "bin/lib/run-tests-baseline-decide/rows.js");
test("DT-rows-overlap: on a table with a row duplicated, two rows match that row's input", () => {
  const D = S.D();
  for (const [id, input] of witnesses()) {
    const clone = Object.assign(roundTrip(D.DECIDE_ROWS.find((r) => r.id === id)), { id: `${id}-clone` });
    const got = rowIds(D.matchDecideRows([...D.DECIDE_ROWS, clone], input)).sort();
    assert.deepEqual(got, [id, `${id}-clone`].sort(), `${id}: detects the overlap`);
  }
});
caseEnd();

caseBegin("DT-rows-gap-detected", "bin/lib/run-tests-baseline-decide/rows.js");
test("DT-rows-gap: on a table with one row removed, zero rows match the input only that row matched", () => {
  const D = S.D();
  for (const r of D.DECIDE_ROWS) assert.ok(witnesses().has(r.id), `the domain has an input matching row ${r.id}`);
  for (const [id, input] of witnesses()) {
    const rest = D.DECIDE_ROWS.filter((r) => r.id !== id);
    assert.deepEqual(rowIds(D.matchDecideRows(rest, input)), [], `removing ${id} detects the gap`);
  }
});
caseEnd();

caseBegin("DT-rows-list-agrees-with-match", "bin/lib/run-tests-baseline-decide.js");
test("DT-rows-list-agrees: listMatchingDecideRows equals matchDecideRows(DECIDE_ROWS, ·) over the whole module domain", () => {
  const D = S.D();
  assert.equal(typeof D.matchDecideRows, "function", "exports matchDecideRows");
  for (const input of D.enumerateDecideInputDomain()) {
    const listed = rowIds(D.listMatchingDecideRows(input)).join(",");
    const matched = rowIds(D.matchDecideRows(D.DECIDE_ROWS, input)).join(",");
    if (listed !== matched || matched === "" || matched.includes(",")) {
      assert.fail(`${JSON.stringify(input)}: listMatchingDecideRows=[${listed}] matchDecideRows=[${matched}] (should match exactly one row)`);
    }
  }
});
caseEnd();
