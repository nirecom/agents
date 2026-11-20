"use strict";
// Private cases of tests/bin/bin-run-tests-baseline-decide-table.js: groups (iii) and (iv).
// (iii) How each kind of branch result (no records, decoy, interrupted, timeout) enters table 1, and
// the case comparison field read per kind. (iv) table 1 case comparison x whether the test file changed.
// The expected values are `rtb_cls_table1` / `rtb_cls_base_pass` in bin/lib/run-tests-baseline-classify.sh.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { caseBegin, caseEnd } = require("../../lib/harness");
const S = require("./_shared");

const { K, CD, IN, R } = S;
const H = (r, hitKind) => Object.assign({}, r, { hitKind });
const ROOT_HIT = "root-decoy-or-worktree-change";
const MISSING_ON_BRANCH = CD("new-case-failure-on-branch", "case-records-missing-on-branch");
const PRE1 = CD("preexisting", "fails-at-base-exit-1");
const NEW1 = CD("new-case-failure-on-branch", "fails-at-base-exit-1-new-lines");
const ALL_NEW = { branchRecordsAsNormal: "new", branchRecordsAsInterrupted: "new", branchRecordsIgnored: "new" };

caseBegin("DT-group-iii-branch-kinds", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-group-iii: how each kind of branch result enters table 1 (kinds that do not read the case comparison result)", () => {
  const cases = [
    { name: "branch unrunnable + base FAIL", br: K.unrunnable, base: K.failNormal, tfc: "unchanged", want: MISSING_ON_BRANCH },
    { name: "branch timeout + base FAIL", br: K.timeout, base: K.failNormal, tfc: "unchanged", want: MISSING_ON_BRANCH },
    { name: "branch watchdog + base FAIL", br: K.watchdog, base: K.failNormal, tfc: "unchanged", want: MISSING_ON_BRANCH },
    { name: "branch unrunnable + base FAIL, changed", br: K.unrunnable, base: K.failNormal, tfc: "changed", want: MISSING_ON_BRANCH },
    { name: "branch decoy + base FAIL, unchanged", br: H(K.failNormal, ROOT_HIT), base: K.failNormal, tfc: "unchanged",
      want: CD("undetermined", "root-decoy-hit-on-branch") },
    { name: "branch decoy + base FAIL, changed", br: H(K.failNormal, ROOT_HIT), base: K.failNormal, tfc: "changed", want: MISSING_ON_BRANCH },
    { name: "branch decoy + base FAIL, change unknown", br: H(K.failNormal, ROOT_HIT), base: K.failNormal, tfc: "unknown", want: MISSING_ON_BRANCH },
    { name: "branch PASS + decoy + base FAIL, unchanged", br: H(K.pass, ROOT_HIT), base: K.failNormal, tfc: "unchanged",
      want: CD("undetermined", "root-decoy-hit-on-branch") },
    { name: "branch decoy + base PASS", br: H(K.failNormal, ROOT_HIT), base: K.pass, tfc: "unchanged", want: MISSING_ON_BRANCH },
    { name: "branch unrunnable + base PASS", br: K.unrunnable, base: K.pass, tfc: "unchanged", want: MISSING_ON_BRANCH },
    // `rtb_cls_base_pass` does not look at BR_TIMEOUT, so a branch timeout with a base PASS is broken.
    { name: "branch timeout + base PASS", br: K.timeout, base: K.pass, tfc: "unchanged", want: CD("broken", "passes-at-base") },
    { name: "branch timeout + base timeout", br: K.timeout, base: K.timeout, tfc: "unchanged", want: CD("undetermined", "timeout-at-base") },
    { name: "branch FAIL + base PASS", br: K.failNormal, base: K.pass, tfc: "changed", want: CD("broken", "passes-at-base") },
  ];
  for (const { name, br, base, tfc, want } of cases) {
    for (const cmp of [{}, ALL_NEW]) {
      const label = `${name} cmp=${JSON.stringify(cmp)}`;
      assert.deepEqual(S.decideOne(IN(br, base, tfc, cmp), label), want, label);
    }
  }
});
caseEnd();

caseBegin("DT-group-iii-comparison-field", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-group-iii-field: exactly one case comparison field is read per kind of branch result", () => {
  const kinds = [
    { name: "FAIL 1 (plain)", br: K.failNormal, field: "branchRecordsAsNormal" },
    { name: "FAIL 3 (plain)", br: K.fail3, field: "branchRecordsAsNormal" },
    { name: "FAIL 1 + guard lines only (the test's own FAIL)", br: H(K.failNormal, "command-guard-hit-only"), field: "branchRecordsAsNormal" },
    { name: "FAIL 124 (interrupted, discrepancy 1)", br: K.fail124, field: "branchRecordsAsInterrupted" },
    { name: "FAIL 142 (interrupted, discrepancy 1)", br: K.fail142, field: "branchRecordsAsInterrupted" },
    { name: "SKIP (no records, discrepancy 5)", br: K.skip, field: "branchRecordsIgnored" },
    { name: "unsupported (no records)", br: K.unsupported, field: "branchRecordsIgnored" },
    // spec-pending: branch side ?/? reading. live reads a state-less rc 124/142 as interrupted and an unknown state X as skip,
    // but the decide input cannot tell the two apart. Here the state-less reading (discrepancy 2) is expected.
    { name: "?/? rc 124 (state-less interrupted)", br: R("?", "?", 124), field: "branchRecordsAsInterrupted" },
    { name: "?/? rc 142 (state-less interrupted)", br: R("?", "?", 142), field: "branchRecordsAsInterrupted" },
    { name: "?/? rc 77 (skip for both state-less and unknown state)", br: R("?", "?", 77), field: "branchRecordsIgnored" },
  ];
  for (const { name, br, field } of kinds) {
    const others = S.CMP_FIELDS.filter((f) => f !== field);
    const onlyRead = Object.assign({ [field]: "new" }, ...others.map((f) => ({ [f]: "same" })));
    const othersNew = Object.assign({ [field]: "same" }, ...others.map((f) => ({ [f]: "new" })));
    assert.deepEqual(S.decideOne(IN(br, K.failNormal, "unchanged", onlyRead), `${name}: ${field}=new`), NEW1, `${name}: ${field}=new`);
    assert.deepEqual(S.decideOne(IN(br, K.failNormal, "unchanged", othersNew), `${name}: others=new`), PRE1, `${name}: the other fields are not read`);
  }
});
caseEnd();

caseBegin("DT-group-iv-table1", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-group-iv: table 1 case comparison x whether the test file changed", () => {
  const byVerdict = {
    same: PRE1,
    new: NEW1,
    "no-records": CD("file-verdict-preexisting", "no-case-records"),
    "branch-missing": CD("new-case-failure-on-branch", "case-records-missing-on-branch"),
    "base-missing": CD("new-case-failure-on-branch", "case-records-missing-at-base"),
    "compare-failed": CD("undetermined", "compare-failed"),
  };
  for (const v of S.CMP_VALUES) {
    for (const tfc of S.TFC) {
      const label = `branchRecordsAsNormal=${v} testFileChange=${tfc}`;
      // A comparison failure comes before the file change. Changed or unknown is test-file-changed.
      const want = v === "compare-failed" ? byVerdict[v]
        : tfc === "unchanged" ? byVerdict[v] : CD("file-verdict-preexisting", "test-file-changed");
      assert.deepEqual(S.decideOne(IN(K.failNormal, K.failNormal, tfc, { branchRecordsAsNormal: v }), label), want, label);
    }
  }
  const cases = [
    { name: "base exit 2 + new", base: R("FAIL", "completed", 2), want: CD("new-case-failure-on-branch", "fails-at-base-exit-2-new-lines") },
    { name: "base exit 124 + new", base: K.fail124, want: CD("new-case-failure-on-branch", "fails-at-base-exit-124-new-lines") },
    { name: "base ?/? rc 3 + new", base: R("?", "?", 3), want: CD("new-case-failure-on-branch", "fails-at-base-exit-3-new-lines") },
  ];
  for (const { name, base, want } of cases) {
    assert.deepEqual(S.decideOne(IN(K.failNormal, base, "unchanged", { branchRecordsAsNormal: "new" }), name), want, name);
  }
});
caseEnd();
