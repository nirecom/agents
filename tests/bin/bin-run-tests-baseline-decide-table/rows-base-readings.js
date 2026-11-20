"use strict";
// Private cases of tests/bin/bin-run-tests-baseline-decide-table.js: group (ii), the merge base side readings.
// The branch result is fixed at FAIL / completed / 1 (a plain failure that enters table 1), the test file is unchanged, every case comparison is same,
// and only the base result varies. The expected values are the readings of the merge base side case statement in bin/run-tests-baseline (lines 190-218).
// A FAIL with only a command guard hit (discrepancy 3) has its reading decided at CONFIRM, so it is not asserted here.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { caseBegin, caseEnd } = require("../../lib/harness");
const S = require("./_shared");

const { K, CD, IN, R } = S;
const H = (r, hitKind) => Object.assign({}, r, { hitKind });
const ROOT_HIT = "root-decoy-or-worktree-change";
const GUARD_ONLY = "command-guard-hit-only";
const U = (d) => CD("undetermined", d);

const CASES = [
  // Flags read before the run result (TIMEDOUT → UNSUPPORTED → DECOY → UNRUNNABLE).
  { name: "launcher timeout", base: K.timeout, want: U("timeout-at-base") },
  { name: "the outer watchdog is also read as timeout", base: K.watchdog, want: U("timeout-at-base") },
  { name: "timeout + root decoy hit: timeout first", base: H(K.timeout, ROOT_HIT), want: U("timeout-at-base") },
  { name: "unsupported", base: K.unsupported, want: U("unsupported-at-base") },
  { name: "unsupported + root decoy hit: unsupported first", base: H(K.unsupported, ROOT_HIT), want: U("unsupported-at-base") },
  { name: "FAIL + root decoy hit", base: H(K.failNormal, ROOT_HIT), want: U("root-decoy-hit-at-base") },
  { name: "PASS + root decoy hit", base: H(K.pass, ROOT_HIT), want: U("root-decoy-hit-at-base") },
  { name: "PASS + guard lines only (no exception on the merge base side)", base: H(K.pass, GUARD_ONLY), want: U("root-decoy-hit-at-base") },
  { name: "SKIP + root decoy hit", base: H(K.skip, ROOT_HIT), want: U("root-decoy-hit-at-base") },
  { name: "unrunnable + root decoy hit: decoy first", base: H(K.unrunnable, ROOT_HIT), want: U("root-decoy-hit-at-base") },
  { name: "unrunnable", base: K.unrunnable, want: U("unrunnable-at-base") },
  // Readings with a state.
  { name: "SKIP", base: K.skip, want: U("skip-at-base") },
  { name: "SKIP rc 0 is also skip", base: R("SKIP", "completed", 0), want: U("skip-at-base") },
  { name: "PASS", base: K.pass, want: CD("broken", "passes-at-base") },
  { name: "FAIL 137", base: K.fail137, want: U("ambiguous-exit-137") },
  { name: "FAIL 143", base: K.fail143, want: U("ambiguous-exit-143") },
  { name: "FAIL 124 is the test's own failure (discrepancy 1)", base: K.fail124, want: CD("preexisting", "fails-at-base-exit-124") },
  { name: "FAIL 142 is the test's own failure (discrepancy 1)", base: K.fail142, want: CD("preexisting", "fails-at-base-exit-142") },
  { name: "FAIL 1", base: K.failNormal, want: CD("preexisting", "fails-at-base-exit-1") },
  { name: "FAIL 3 (any other exit)", base: K.fail3, want: CD("preexisting", "fails-at-base-exit-3") },
  { name: "FAIL 77 is a failure because the state comes first", base: R("FAIL", "completed", 77), want: CD("preexisting", "fails-at-base-exit-77") },
  // Readings without a state (rc only; discrepancy 2).
  { name: "?/? rc 77", base: R("?", "?", 77), want: U("skip-at-base") },
  { name: "?/? rc 0", base: R("?", "?", 0), want: CD("broken", "passes-at-base") },
  { name: "?/? rc 124", base: R("?", "?", 124), want: U("ambiguous-exit-124") },
  { name: "?/? rc 142", base: R("?", "?", 142), want: U("ambiguous-exit-142") },
  { name: "?/? rc 137", base: R("?", "?", 137), want: U("ambiguous-exit-137") },
  { name: "?/? rc 143", base: R("?", "?", 143), want: U("ambiguous-exit-143") },
  { name: "?/? rc 1", base: R("?", "?", 1), want: CD("preexisting", "fails-at-base-exit-1") },
  { name: "?/? rc 3", base: R("?", "?", 3), want: CD("preexisting", "fails-at-base-exit-3") },
  { name: "?/? rc 78", base: R("?", "?", 78), want: CD("preexisting", "fails-at-base-exit-78") },
];

caseBegin("DT-group-ii-base-readings", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-group-ii: the merge base side reading rows (branch is a plain FAIL, unchanged, every comparison same)", () => {
  for (const { name, base, want } of CASES) {
    assert.deepEqual(S.decideOne(IN(K.failNormal, base), name), want, name);
  }
});
caseEnd();

caseBegin("DT-group-ii-base-setup-failure", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-group-ii-setup: a setup failure at the merge base side is exec-setup-failed (a row output, or an outside-decide id)", () => {
  const out = S.decideOne(IN(K.failNormal, K.setup), "setup failure at the merge base side");
  const ok = (out.class === "undetermined" && out.detail === "exec-setup-failed") || out.decidedOutsideDecide === "exec-setup-failed";
  assert.ok(ok, `setup failure at the merge base side: ${JSON.stringify(out)}`);
});
caseEnd();
