"use strict";
// Tests: hooks/workflow-state/glossary-check/rescan.js
// Tags: TL1, hooks, workflow-state, glossary, glossary-check, rescan, scope:issue-specific
// #2962: rescanVerdict over a glossary-only change. The scan (bin/lib/glossary-drift/scan.js) is
// stubbed on its cached module, which rescan.js requires at call time: a non-array result and a
// throw are the error verdict; the same findings stay current; a vanished or new finding, or a
// moved term_fields sha, is stale naming the term; any other change set is stale without a rescan.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const RESCAN = path.join(ROOT, "hooks/workflow-state/glossary-check/rescan.js");
const SCAN = path.join(ROOT, "bin/lib/glossary-drift/scan.js");

const FP = (c) => c.repeat(64);
const TERM = "glossary drift";
const finding = { term: TERM, norm: TERM, variant: "glossary-drift", where: "src/a.js:2" };
const TF = { [TERM]: FP("e") };
const rec = { findings: [finding], term_fields: TF };

// verdict(scanResult, opts) -> rescanVerdict with scanStageInputs stubbed, restored afterwards.
function verdict(scan, o) {
  const opts = o || {};
  const S = require(SCAN);
  const real = S.scanStageInputs;
  let calls = 0;
  S.scanStageInputs = () => { calls += 1; if (scan instanceof Error) throw scan; return scan; };
  try {
    const v = require(RESCAN).rescanVerdict(opts.rec || rec, opts.changed || ["glossary"], {}, opts.termFields || TF);
    return { v, calls };
  } finally {
    S.scanStageInputs = real;
  }
}

caseBegin("rescanVerdict error branch: the scan returns a non-array or throws", "hooks/workflow-state/glossary-check/rescan.js");
test("rescanVerdict error branch: the scan returns a non-array or throws", () => {
  for (const [label, bad] of [["null", null], ["undefined", undefined], ["an object", { findings: [] }], ["a string", "x"]]) {
    const { v, calls } = verdict(bad);
    assert.strictEqual(calls, 1, `${label}: the scan ran once`);
    assert.ok(typeof v.error === "string" && v.error.length > 0, `${label}: error verdict ${JSON.stringify(v)}`);
    assert.ok(!("current" in v), `${label}: no current field ${JSON.stringify(v)}`);
  }
  const { v } = verdict(new Error("fixture scan failure"));
  assert.strictEqual(v.error, "fixture scan failure", JSON.stringify(v));
});
caseEnd();

caseBegin("rescanVerdict current and stale verdicts over a glossary-only change", "hooks/workflow-state/glossary-check/rescan.js");
test("rescanVerdict current and stale verdicts over a glossary-only change", () => {
  assert.deepStrictEqual(verdict([Object.assign({}, finding)]).v, { current: true }, "same findings, same term_fields");
  assert.deepStrictEqual(verdict([]).v, { current: false, terms: [TERM] }, "the finding vanished");
  const extra = { term: "concern ledger", norm: "concern ledger", variant: "concern-ledger", where: "src/a.js:3" };
  assert.deepStrictEqual(verdict([finding, extra]).v, { current: false, terms: ["concern ledger"] }, "a new finding");
  assert.deepStrictEqual(verdict([finding], { termFields: { [TERM]: FP("f") } }).v, { current: false, terms: [TERM] },
    "the term's matching fields moved");
});
caseEnd();

caseBegin("rescanVerdict skips the scan unless only the glossary changed on a record with term_fields", "hooks/workflow-state/glossary-check/rescan.js");
test("rescanVerdict skips the scan unless only the glossary changed on a record with term_fields", () => {
  const cases = [
    ["artifact and glossary changed", { changed: ["artifact", "glossary"] }],
    ["only the artifact changed", { changed: ["artifact"] }],
    ["nothing named as changed", { changed: [] }],
    ["a record without term_fields", { rec: { findings: [finding] } }],
  ];
  for (const [label, opts] of cases) {
    const { v, calls } = verdict(null, opts);
    assert.deepStrictEqual(v, { current: false }, `${label}: ${JSON.stringify(v)}`);
    assert.strictEqual(calls, 0, `${label}: the scan did not run`);
  }
});
caseEnd();
