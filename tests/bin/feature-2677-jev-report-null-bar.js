"use strict";
// Tests: bin/lib/jev-report-aggregate/legacy.js
// Tags: TL1, bin, jev, jev-report, legacy, low-confidence, threshold-by-answer, null-threshold, boundary-values, scope:issue-specific
// #2677: a per-direction threshold whose direction is null (never adopted) makes every answer
// in that direction count as below the low-confidence bar, whatever its confidence; the other
// direction still compares against its number, and a scalar threshold keeps its old reading.
// belowBar is module-private, so each row goes through the exported aggregatePoint.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.join(__dirname, "..", "..");
const { aggregatePoint } = require(path.join(REPO, "bin", "lib", "jev-report-aggregate", "legacy.js"));
const { REGISTRY } = require(path.join(REPO, "hooks", "lib", "jev", "registry.js"));

const restore = isolate();
after(() => restore());

const S2 = "S2-architecture";
// lowRate(p, threshold): S2's low-confidence rate over one answered v1 record with S2 = p.
const lowRate = (p, threshold) => aggregatePoint(
  [{ version: 1, point: "complexity-judge", jev: { status: "ok", probabilities: { [S2]: p } } }],
  threshold,
).low_confidence_rate_by_signal[S2];

caseBegin("null-direction-below-bar", "bin/lib/jev-report-aggregate/legacy.js");
const NULL_FALSE = { true: 0.7, false: null };
// [p, expected S2 low-confidence rate, why]
const ROWS = [
  [0.01, 1, "false side null: conf 0.99 is still below (never adopted)"],
  [0.49, 1, "false side null: conf 0.51 below"],
  [0.7, 0, "true side at its bar 0.7: not below"],
  [0.69, 1, "true side 0.69 < 0.7: below"],
  [0.99, 0, "true side 0.99: not below"],
];
for (const [p, want, why] of ROWS) {
  test(`{true:0.7,false:null}, p=${p} -> ${want} (${why})`, () => {
    assert.strictEqual(lowRate(p, NULL_FALSE), want);
  });
}
test("null true side mirrors it: p=0.99 below, p=0.01 compared against false 0.7 (not below)", () => {
  assert.strictEqual(lowRate(0.99, { true: null, false: 0.7 }), 1);
  assert.strictEqual(lowRate(0.01, { true: null, false: 0.7 }), 0);
});
test("contrast: a numeric false side 0.7 does not count p=0.01 as below", () => {
  assert.strictEqual(lowRate(0.01, { true: 0.9, false: 0.7 }), 0);
});
test("the shipped complexity-judge threshold counts p=0.01 as below and p=0.7 as not", () => {
  const thr = REGISTRY["complexity-judge"].confidence_threshold_by_answer;
  assert.strictEqual(thr.false, null, "premise: the shipped false side is null");
  assert.strictEqual(lowRate(0.01, thr), 1);
  assert.strictEqual(lowRate(0.7, thr), 0);
});
test("rate over mixed records: 3 of 4 below under {true:0.7,false:null}", () => {
  const recs = [0.01, 0.49, 0.7, 0.69].map((p) => ({ version: 1, point: "complexity-judge", jev: { status: "ok", probabilities: { [S2]: p } } }));
  const r = aggregatePoint(recs, NULL_FALSE);
  assert.strictEqual(r.low_confidence_rate_n, 4);
  assert.strictEqual(r.low_confidence_rate_by_signal[S2], 0.75);
});
caseEnd();

caseBegin("scalar-threshold-unchanged", "bin/lib/jev-report-aggregate/legacy.js");
// [p, expected, why] under the scalar 0.75 cut.
const SCALAR = [
  [0.25, 0, "conf 0.75 at the bar"],
  [0.26, 1, "conf 0.74 below"],
  [0.01, 0, "conf 0.99"],
  [0.8, 0, "conf 0.8"],
  [0.7, 1, "conf 0.7 below"],
];
for (const [p, want, why] of SCALAR) {
  test(`scalar 0.75, p=${p} -> ${want} (${why})`, () => {
    assert.strictEqual(lowRate(p, 0.75), want);
  });
}
caseEnd();
