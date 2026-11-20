#!/usr/bin/env node
"use strict";
// Tests: bin/lib/run-tests-baseline-decide.js, bin/lib/run-tests-baseline-decide/evaluate.js, bin/lib/run-tests-baseline-decide/details-decided-outside-decide.js, bin/lib/run-tests-baseline-decide/recorded-discrepancies.js
// Tags: TL1, bin, run-tests-baseline, decide, table-driven, scope:common
// #3069 / #3070 — the decide(input) table: the rows of groups (i)-(iv), exhaustiveness (exactly one row for every input),
// the list of details decided outside decide, the recorded discrepancies, reaching APPROVABLE_UNDETERMINED, corpus (3).
// Contract: detail plan `## decide spec (#3069)`, `## recorded discrepancies (#3070)`.
// The input-key case is here; the other cases live in the files of ./bin-run-tests-baseline-decide-table/, with their markers.
// TL3 gap: the comparison that feeds real run inputs (capture and case comparison) through decide is owned by corpus (1)(2) and the in-run shadow.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const S = require("./bin-run-tests-baseline-decide-table/_shared");

const restore = isolate();
after(() => restore());

caseBegin("DT-input-keys", "bin/lib/run-tests-baseline-decide.js");
test("DT-input-keys: the decide input has only the 4 keys of the intent; more or fewer throws", () => {
  const D = S.D();
  assert.deepEqual([...D.DECIDE_INPUT_KEYS].sort(), ["baseResult", "branchResult", "caseComparison", "testFileChange"]);
  const good = S.IN(S.K.failNormal, S.K.failNormal);
  assert.doesNotThrow(() => D.decide(good), "valid input");
  for (const k of Object.keys(good)) {
    const missing = Object.assign({}, good);
    delete missing[k];
    assert.throws(() => D.decide(missing), Error, `input without ${k}`);
  }
  assert.throws(() => D.decide(Object.assign({}, good, { comparisonSide: "branch" })), Error, "input with comparison side added");
  assert.throws(() => D.decide(Object.assign({}, good, { state: "FAIL" })), Error, "input with state added");
});
caseEnd();

require("./bin-run-tests-baseline-decide-table/rows-without-base-result");
require("./bin-run-tests-baseline-decide-table/rows-base-readings");
require("./bin-run-tests-baseline-decide-table/rows-branch-kinds");
require("./bin-run-tests-baseline-decide-table/exhaustiveness");
require("./bin-run-tests-baseline-decide-table/details-and-discrepancies");
require("./bin-run-tests-baseline-decide-table/corpus-past-state");
