"use strict";
// Private cases of tests/bin/bin-run-tests-baseline-decide-table.js: group (i), inputs whose base result is null.
// Splits the table 2 readings (`rtb_branch_run_one` / `rtb_branch_classify`) into rows decided by the branch result alone
// (kill's ambiguous-exit-N, the decidedOutsideDecide of exit-<N>-then-pass) and needsBaseResult.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { caseBegin, caseEnd } = require("../../lib/harness");
const S = require("./_shared");

const { K, CD, IN, R } = S;
const H = (r, hitKind) => Object.assign({}, r, { hitKind });
const ROOT_HIT = "root-decoy-or-worktree-change";
const GUARD_ONLY = "command-guard-hit-only";
const NEEDS = { needsBaseResult: true };
const OUTSIDE_PASS = { decidedOutsideDecide: "exit-<N>-then-pass" };

// Also checks that the rest of the input (testFileChange and caseComparison) does not change the output.
const VARIANTS = [
  ["unchanged", {}],
  ["changed", { branchRecordsAsNormal: "new", branchRecordsAsInterrupted: "new", branchRecordsIgnored: "new" }],
  ["unknown", { branchRecordsAsNormal: "compare-failed", branchRecordsAsInterrupted: "no-records", branchRecordsIgnored: "base-missing" }],
];

const CASES = [
  { name: "PASS (passed on rerun) is exit-<N>-then-pass", br: K.pass, want: OUTSIDE_PASS },
  { name: "PASS rc 3 (state first) is exit-<N>-then-pass", br: R("PASS", "completed", 3), want: OUTSIDE_PASS },
  { name: "PASS + root decoy hit is a decoy, so the base is needed", br: H(K.pass, ROOT_HIT), want: NEEDS },
  { name: "PASS + guard lines only (the exception is FAIL only) is a decoy", br: H(K.pass, GUARD_ONLY), want: NEEDS },
  { name: "FAIL 137 is a kill", br: K.fail137, want: CD("undetermined", "ambiguous-exit-137") },
  { name: "FAIL 143 is a kill", br: K.fail143, want: CD("undetermined", "ambiguous-exit-143") },
  { name: "FAIL 137 + guard lines only is a kill as the test's own FAIL", br: H(K.fail137, GUARD_ONLY),
    want: CD("undetermined", "ambiguous-exit-137") },
  { name: "FAIL 137 + root decoy hit: decoy first", br: H(K.fail137, ROOT_HIT), want: NEEDS },
  { name: "FAIL 1 goes to table 1", br: K.failNormal, want: NEEDS },
  { name: "FAIL 3 goes to table 1", br: K.fail3, want: NEEDS },
  { name: "FAIL 1 + guard lines only goes to table 1", br: H(K.failNormal, GUARD_ONLY), want: NEEDS },
  { name: "FAIL 1 + root decoy hit", br: H(K.failNormal, ROOT_HIT), want: NEEDS },
  { name: "FAIL 124 is interrupted", br: K.fail124, want: NEEDS },
  { name: "FAIL 142 is interrupted", br: K.fail142, want: NEEDS },
  { name: "SKIP goes to the base as no records (discrepancy 5)", br: K.skip, want: NEEDS },
  { name: "unsupported", br: K.unsupported, want: NEEDS },
  { name: "unrunnable", br: K.unrunnable, want: NEEDS },
  { name: "launcher timeout", br: K.timeout, want: NEEDS },
  { name: "outer watchdog", br: K.watchdog, want: NEEDS },
  // ?/? is the image of both state-less (read by rc) and unknown state (skip). Either reading needs the base.
  { name: "?/? rc 124 (state-less is interrupted, unknown state is skip)", br: R("?", "?", 124), want: NEEDS },
  { name: "?/? rc 142 (state-less is interrupted, unknown state is skip)", br: R("?", "?", 142), want: NEEDS },
  { name: "?/? rc 1 (state-less is fail, unknown state is skip)", br: R("?", "?", 1), want: NEEDS },
];

caseBegin("DT-group-i-without-base-result", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-group-i: an input with baseResult null is decided by the branch result alone, or returns needsBaseResult", () => {
  for (const { name, br, want } of CASES) {
    for (const [tfc, cmp] of VARIANTS) {
      const label = `${name} [${tfc}]`;
      const out = S.decideOne(IN(br, null, tfc, cmp), label);
      assert.deepEqual(out, want, label);
    }
  }
});
caseEnd();

caseBegin("DT-group-i-setup-failure", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-group-i-setup: a setup failure at the branch side is exec-setup-failed (a row output, or an outside-decide id)", () => {
  for (const base of [null, K.failNormal]) {
    const out = S.decideOne(IN(K.setup, base), `setup failure base=${JSON.stringify(base)}`);
    const ok = (out.class === "undetermined" && out.detail === "exec-setup-failed") || out.decidedOutsideDecide === "exec-setup-failed";
    assert.ok(ok, `setup failure: ${JSON.stringify(out)}`);
  }
});
caseEnd();
