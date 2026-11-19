"use strict";
// Private cases of tests/bin/bin-run-tests-baseline-decide-table.js: the list of details decided outside decide,
// the recorded discrepancies (their shape, and that a recorded matcher really produces a mismatch), reaching APPROVABLE_UNDETERMINED,
// and the dependency direction (decide and the parser depend neither on disposition.js nor on the shell lib).
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd } = require("../../lib/harness");
const S = require("./_shared");

const SHA = "0123456789abcdef0123456789abcdef01234567";
// id → [detail it must match, class it must contain]
const OUTSIDE = {
  "worktree-create-failed": ["worktree-create-failed", "undetermined"],
  "missing-at-base": ["missing-at-base", "undetermined"],
  "home-claude-ref": ["home-claude-ref", "undetermined"],
  "budget-exhausted": ["budget-exhausted", "undetermined"],
  "exceeds-budget": ["exceeds-budget", "undetermined"],
  "exec-setup-failed": ["exec-setup-failed", "undetermined"],
  "exit-<N>-then-pass": ["exit-124-then-pass", "flaky-timeout-on-branch"],
  "base-launcher-predates-result-conversion": ["base-launcher-predates-result-conversion", "undetermined"],
  "state-<X>-at-base": ["state-WEIRD_X-at-base", "undetermined"],
};
const REUSE = {
  "ledger-same-base": ["ledger-same-base-new-lines", "new-case-failure-on-branch"],
  "inherited-from-*": [`inherited-from-${SHA}`, "preexisting-inherited"],
  "preexisting-inherited": null,
};

function checkList(list, want, label) {
  assert.ok(Array.isArray(list), `${label} is an array`);
  for (const e of list) {
    assert.ok(typeof e.id === "string" && e.detailPattern instanceof RegExp, `${label} ${e.id}: id and detailPattern`);
    assert.ok(Array.isArray(e.classes) && e.classes.length > 0, `${label} ${e.id}: classes`);
    assert.ok(typeof e.decidingInput === "string" && e.decidingInput.length > 0, `${label} ${e.id}: decidingInput`);
  }
  for (const [id, probe] of Object.entries(want)) {
    const e = list.find((x) => x.id === id);
    assert.ok(e, `${label} contains ${id}`);
    if (probe) assert.ok(e.detailPattern.test(probe[0]) && e.classes.includes(probe[1]), `${label} ${id}: matches ${probe[1]}/${probe[0]}`);
  }
}

caseBegin("DT-details-decided-outside-decide", "bin/lib/run-tests-baseline-decide/details-decided-outside-decide.js");
test("DT-outside: the list of details decided outside decide and the reuse-path list", () => {
  const D = S.D();
  checkList(D.DETAILS_DECIDED_OUTSIDE_DECIDE, OUTSIDE, "DETAILS_DECIDED_OUTSIDE_DECIDE");
  checkList(D.DETAILS_FROM_REUSE_PATH, REUSE, "DETAILS_FROM_REUSE_PATH");
  const exitPass = D.DETAILS_DECIDED_OUTSIDE_DECIDE.find((x) => x.id === "exit-<N>-then-pass");
  assert.ok(exitPass.detailPattern.test("exit-1-then-pass") && exitPass.classes.includes("passes-alone-on-branch"), "exit-1-then-pass");
  assert.ok(D.DETAILS_FROM_REUSE_PATH.find((x) => x.id === "ledger-same-base").detailPattern.test("ledger-same-base"), "ledger-same-base");
});
caseEnd();

caseBegin("DT-recorded-discrepancies-shape", "bin/lib/run-tests-baseline-decide/recorded-discrepancies.js");
test("DT-discrepancy-shape: fields and judgments of the records of discrepancies 1-6", () => {
  const D = S.D();
  const recs = D.RECORDED_DISCREPANCIES;
  const judgment = { 1: "intended", 2: "intended", 3: "inconsistent", 4: "inconsistent", 5: "intended", 6: "intended" };
  const outside = { 4: "base-launcher-predates-result-conversion", 6: "state-<X>-at-base" };
  assert.deepEqual(recs.map((r) => r.discrepancyNumber).sort(), [1, 2, 3, 4, 5, 6], "six discrepancies, 1-6");
  assert.equal(new Set(recs.map((r) => r.id)).size, 6, "ids are unique");
  const outsideIds = new Set(D.DETAILS_DECIDED_OUTSIDE_DECIDE.map((x) => x.id));
  for (const r of recs) {
    const n = r.discrepancyNumber;
    const L = `discrepancy ${n}`;
    assert.equal(r.judgment, judgment[n], `${L}: judgment`);
    assert.ok(typeof r.reason === "string" && r.reason.length > 0, `${L}: reason`);
    assert.ok((typeof r.evidence === "string" && r.evidence.length > 0) || (Array.isArray(r.evidence) && r.evidence.length > 0), `${L}: evidence`);
    assert.equal(r.confirmedBy, [3, 4, 6].includes(n) ? "user" : "evidence", `${L}: confirmedBy`);
    assert.equal(r.handoff, "#3071", `${L}: handoff`);
    assert.ok(Array.isArray(r.dependsOn), `${L}: dependsOn is an array`);
    assert.equal(r.readingOutsideDecide, outside[n] || null, `${L}: readingOutsideDecide`);
    if (r.readingOutsideDecide) assert.ok(outsideIds.has(r.readingOutsideDecide), `${L}: points at an id of the outside list`);
    assert.ok(typeof r.combination.matcher === "function" && typeof r.combination.description === "string", `${L}: combination`);
    for (const side of ["branchSide", "mergeBaseSide"]) {
      const lr = r.liveReading[side];
      assert.ok(lr && lr.example && typeof lr.class === "string" && typeof lr.detail === "string", `${L} ${side}: liveReading`);
      assert.equal(r.combination.matcher(lr.example), true, `${L} ${side}: the matcher matches the example`);
    }
  }
  assert.ok(recs.find((r) => r.discrepancyNumber === 2).dependsOn.includes("APPROVABLE_UNDETERMINED"), "discrepancy 2 depends on APPROVABLE_UNDETERMINED");
  for (const r of recs) {
    assert.equal(r.combination.matcher(S.IN(S.K.failNormal, S.K.failNormal)), false, `discrepancy ${r.discrepancyNumber}: does not match a plain FAIL pair`);
  }
});
caseEnd();

caseBegin("DT-recorded-discrepancies-matcher", "bin/lib/run-tests-baseline-decide/recorded-discrepancies.js");
test("DT-discrepancy-matcher: for intended, decide equals the current code on both the branch side and the merge base side; inconsistent produces a mismatch", () => {
  const D = S.D();
  for (const r of D.RECORDED_DISCREPANCIES) {
    const L = `discrepancy ${r.discrepancyNumber}`;
    const sides = ["branchSide", "mergeBaseSide"].map((side) => {
      const lr = r.liveReading[side];
      const out = S.decideOne(lr.example, `${L} ${side}`);
      const outsideEntry = D.DETAILS_DECIDED_OUTSIDE_DECIDE.find((x) => x.id === r.readingOutsideDecide);
      const readOutside = !!outsideEntry && outsideEntry.detailPattern.test(lr.detail);
      return { side, lr, out, readOutside, match: out.class === lr.class && out.detail === lr.detail };
    });
    if (r.readingOutsideDecide) {
      assert.ok(sides.some((s) => s.readOutside), `${L}: one current reading is read through the outside list (${r.readingOutsideDecide})`);
      for (const s of sides.filter((x) => !x.readOutside)) assert.ok(s.match, `${L} ${s.side}: the decide row equals the current code`);
    } else if (r.judgment === "intended") {
      for (const s of sides) assert.ok(s.match, `${L} ${s.side}: ${JSON.stringify(s.out)} is the current ${s.lr.class}/${s.lr.detail}`);
    } else {
      assert.ok(sides.some((s) => !s.match), `${L}: an inconsistent matcher produces a mismatch`);
    }
  }
});
caseEnd();

caseBegin("DT-approvable-undetermined-reachable", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-approvable: every APPROVABLE_UNDETERMINED detail is reachable from decide", () => {
  const { APPROVABLE_UNDETERMINED } = require(S.DISPOSITION);
  const reached = new Set();
  for (const input of S.D().enumerateDecideInputDomain()) {
    const out = S.D().decide(input);
    if (out.class === "undetermined") reached.add(out.detail);
  }
  for (const d of APPROVABLE_UNDETERMINED) assert.ok(reached.has(d), `${d} is reachable`);
});
caseEnd();

caseBegin("DT-dependency-direction", "bin/lib/run-tests-baseline-decide.js");
test("DT-deps: decide and the parser depend neither on disposition.js nor on the shell lib", () => {
  const code = `require(${JSON.stringify(S.DECIDE)});require(${JSON.stringify(S.PARSER)});` +
    "process.stdout.write(JSON.stringify(Object.keys(require.cache)))";
  const r = spawnSync(process.execPath, ["-e", code], { encoding: "utf8", timeout: 30000 });
  assert.equal(r.status, 0, `the modules load: ${r.stderr}`);
  const loaded = JSON.parse(r.stdout).map((p) => p.replace(/\\/g, "/"));
  assert.ok(loaded.some((p) => p.endsWith("/bin/lib/run-tests-baseline-decide.js")), "the decide entrypoint was loaded");
  for (const p of loaded) {
    assert.ok(!p.includes("/run-tests-baseline-evidence/"), `${p}: no dependency on the disposition.js side`);
    assert.ok(!p.endsWith(".sh"), `${p}: does not load the shell lib`);
  }
});
caseEnd();

const find = (input, live) => S.D().findRecordForMismatch(input, live);
const recId = (rec) => (rec ? rec.id : null);
const GUARD_FAIL = Object.assign({}, S.K.failNormal, { hitKind: "command-guard-hit-only" });
const STATE_LESS = (rc) => S.R("?", "?", rc);
const BRANCH_MISSING = { branchRecordsIgnored: "branch-missing" };
const MISSING_ON_BRANCH = S.CD("new-case-failure-on-branch", "case-records-missing-on-branch");

caseBegin("DT-find-record-live-reading", "bin/lib/run-tests-baseline-decide/recorded-discrepancies.js");
test("DT-find-record-live: a record is returned not on the combination alone, but only when the live (class, detail) is the recorded reading", () => {
  const atBase = S.IN(S.K.failNormal, GUARD_FAIL);
  assert.equal(recId(find(atBase, S.CD("undetermined", "root-decoy-hit-at-base"))), "discrepancy-3", "live that reads a guard-only FAIL at the merge base side as a decoy");
  assert.equal(recId(find(atBase, S.CD("broken", "passes-at-base"))), null, "live unrelated to the recorded reading");
  const onBranch = S.IN(GUARD_FAIL, S.K.failNormal);
  assert.equal(recId(find(onBranch, S.CD("undetermined", "root-decoy-hit-at-base"))), null, "the merge base side reading on a guard-only FAIL at the branch side");
});
caseEnd();

caseBegin("DT-find-record-intended-null", "bin/lib/run-tests-baseline-decide/recorded-discrepancies.js");
test("DT-find-record-intended: on inputs that match only the intended discrepancies 1, 2, 5, no record is returned whatever live is", () => {
  for (const n of [1, 2, 5]) {
    const rec = S.D().RECORDED_DISCREPANCIES.find((r) => r.discrepancyNumber === n);
    assert.equal(rec.explainsShadowMismatch, false, `discrepancy ${n}: explainsShadowMismatch is false`);
    for (const side of ["branchSide", "mergeBaseSide"]) {
      const lr = rec.liveReading[side];
      for (const live of [S.CD(lr.class, lr.detail), S.CD("broken", "passes-at-base")]) {
        assert.equal(recId(find(lr.example, live)), null, `discrepancy ${n} ${side} live=${live.class}/${live.detail}`);
      }
    }
  }
});
caseEnd();

caseBegin("DT-find-record-discrepancy-6", "bin/lib/run-tests-baseline-decide/recorded-discrepancies.js");
test("DT-find-record-6: an unknown state explains live that reads state-<X>-at-base at the merge base side and skip at the branch side", () => {
  const atBase = S.IN(S.K.failNormal, STATE_LESS(1));
  assert.equal(recId(find(atBase, S.CD("undetermined", "state-WEIRD-at-base"))), "discrepancy-6", "merge base side");
  for (const rc of [1, 0]) {
    const onBranch = S.IN(STATE_LESS(rc), S.K.failNormal, "unchanged", BRANCH_MISSING);
    assert.equal(recId(find(onBranch, MISSING_ON_BRANCH)), "discrepancy-6", `branch side ?/? rc ${rc}`);
  }
});
caseEnd();

caseBegin("DT-find-record-discrepancy-4", "bin/lib/run-tests-baseline-decide/recorded-discrepancies.js");
test("DT-find-record-4: explains live that reads a state-less FAIL at the merge base side as an old launcher", () => {
  const recs = S.D().RECORDED_DISCREPANCIES;
  for (const n of [3, 4, 6]) {
    assert.equal(recs.find((r) => r.discrepancyNumber === n).explainsShadowMismatch, true, `discrepancy ${n}: explainsShadowMismatch is true`);
  }
  const atBase = S.IN(S.K.failNormal, STATE_LESS(1));
  const live = S.CD("undetermined", "base-launcher-predates-result-conversion");
  assert.equal(recId(find(atBase, live)), "discrepancy-4", "?/? rc 1 at the merge base side");
});
caseEnd();
