"use strict";
// decide(input): determines (class, detail) from two comparison side results, the test file change status, and the case comparison.
// The logic lives in ./run-tests-baseline-decide/; this file is dispatch and re-export only.
const { evaluate, matchDecideRows, DECIDE_INPUT_KEYS } = require("./run-tests-baseline-decide/evaluate");
const { DECIDE_ROWS, enumerateComparisonSideResultDomain, enumerateDecideInputDomain } = require("./run-tests-baseline-decide/rows");
const { DETAILS_DECIDED_OUTSIDE_DECIDE, DETAILS_FROM_REUSE_PATH } = require("./run-tests-baseline-decide/details-decided-outside-decide");
const { RECORDED_DISCREPANCIES, findRecordForMismatch } = require("./run-tests-baseline-decide/recorded-discrepancies");

const decide = (input) => evaluate(DECIDE_ROWS, input).output;
const explainDecision = (input) => { const r = evaluate(DECIDE_ROWS, input); return { rowId: r.rowId, fieldRead: r.fieldRead }; };
const listMatchingDecideRows = (input) => matchDecideRows(DECIDE_ROWS, input);

module.exports = {
  decide, explainDecision, listMatchingDecideRows, matchDecideRows, DECIDE_INPUT_KEYS, DECIDE_ROWS,
  enumerateComparisonSideResultDomain, enumerateDecideInputDomain,
  DETAILS_DECIDED_OUTSIDE_DECIDE, DETAILS_FROM_REUSE_PATH, RECORDED_DISCREPANCIES, findRecordForMismatch,
};
