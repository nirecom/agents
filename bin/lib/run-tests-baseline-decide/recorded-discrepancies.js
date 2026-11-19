"use strict";
// Discrepancy records: combinations 1-6 where live reads the branch side and the merge base side differently.
// intended: decide matches live on either comparison side; inconsistent: decide picks one comparison side's reading.
// shadow marks a live/decide mismatch recorded:<id> when the combination and the live reading per comparison side explain it.
// reading per comparison side: { via: "decide" } (same reading as decide; explains no mismatch),
// { via: "decide", rewriteSide } (decide reads the input with that comparison side rewritten), { via: "outside", outsideId }.
const { evaluate } = require("./evaluate");
const { DECIDE_ROWS } = require("./rows");
const { DETAILS_DECIDED_OUTSIDE_DECIDE } = require("./details-decided-outside-decide");

const R =(verdict, termination, exitCode, hitKind = "none") => ({ verdict, termination, exitCode, hitKind });
const SAME = { branchRecordsAsNormal: "same", branchRecordsAsInterrupted: "same", branchRecordsIgnored: "same" };
const IN = (branchResult, baseResult, testFileChange = "unchanged", cmp = {}) =>
  ({ branchResult, baseResult, testFileChange, caseComparison: Object.assign({}, SAME, cmp) });
const FAIL1 = R("FAIL", "completed", 1);
const GUARD_FAIL = R("FAIL", "completed", 1, "command-guard-hit-only");

const SIDES = [["branchResult", "branchSide"], ["baseResult", "mergeBaseSide"]];
const isResult = (r) => !!r && typeof r === "object";
const sides = (input) => SIDES.map(([k]) => input && input[k]).filter(isResult);
const combo = (description, sideMatcher) =>
  ({ description, sideMatcher, matcher: (input) => sides(input).some(sideMatcher) });
const stateLess = (r) => r.verdict === "?" && r.termination === "?";
const AS_DECIDE = Object.freeze({ via: "decide" });
const live = (example, cls, detail, reading = AS_DECIDE) => ({ example, class: cls, detail, reading });

const base = (n, judgment, confirmedBy, fields) => Object.freeze(Object.assign({
  id: `discrepancy-${n}`, discrepancyNumber: n, judgment, confirmedBy, handoff: "#3071",
  dependsOn: [], readingOutsideDecide: null, explainsShadowMismatch: false,
}, fields));

const RECORDED_DISCREPANCIES = Object.freeze([
  base(1, "intended", "evidence", {
    reason: "The branch side reads FAIL with rc 124/142 as interrupted (case records read as cut off); the merge base side reads it as the test's own failure.",
    evidence: ["bin/lib/run-tests-baseline-branch.sh rtb_branch_run_one", "bin/run-tests-baseline merge base side case statement"],
    dependsOn: ["caseComparison.branchRecordsAsInterrupted"],
    combination: combo("either comparison side is FAIL / completed with exit code 124 or 142",
      (r) => r.verdict === "FAIL" && r.termination === "completed" && [124, 142].includes(r.exitCode)),
    liveReading: {
      branchSide: live(IN(R("FAIL", "completed", 124), FAIL1, "unchanged", { branchRecordsAsInterrupted: "same" }), "preexisting", "fails-at-base-exit-1"),
      mergeBaseSide: live(IN(FAIL1, R("FAIL", "completed", 124)), "preexisting", "fails-at-base-exit-124"),
    },
  }),
  base(2, "intended", "evidence", {
    reason: "A state-less result is read by rc alone. 137/143 on the branch side and 124/137/142/143 on the merge base side are ambiguous-exit-N.",
    evidence: ["bin/lib/run-tests-baseline-branch.sh rtb_branch_run_one", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js APPROVABLE_UNDETERMINED"],
    dependsOn: ["APPROVABLE_UNDETERMINED"],
    combination: combo("either comparison side is ?/? with exit code 124/137/142/143",
      (r) => stateLess(r) && [124, 137, 142, 143].includes(r.exitCode)),
    liveReading: {
      branchSide: live(IN(R("?", "?", 137), null), "undetermined", "ambiguous-exit-137"),
      mergeBaseSide: live(IN(FAIL1, R("?", "?", 124)), "undetermined", "ambiguous-exit-124"),
    },
  }),
  base(3, "inconsistent", "user", {
    reason: "The branch side reads a FAIL with only a command guard hit as the test's own FAIL; the merge base side reads it as a decoy. decide reads it as FAIL.",
    evidence: ["bin/lib/run-tests-baseline-branch.sh rtb_branch_guard_only_fail", "bin/run-tests-baseline merge base side RTB_EXEC_DECOY"],
    explainsShadowMismatch: true,
    combination: combo("either comparison side is a FAIL with only a command guard hit",
      (r) => r.hitKind === "command-guard-hit-only" && r.verdict === "FAIL"),
    liveReading: {
      branchSide: live(IN(GUARD_FAIL, FAIL1), "preexisting", "fails-at-base-exit-1"),
      mergeBaseSide: live(IN(FAIL1, GUARD_FAIL), "undetermined", "root-decoy-hit-at-base",
        { via: "decide", rewriteSide: { hitKind: "root-decoy-or-worktree-change" } }),
    },
  }),
  base(4, "inconsistent", "user", {
    reason: "The branch side reads a state-less FAIL by rc; the merge base side reads it as an outdated launcher for a wrapper language.",
    evidence: ["bin/run-tests-baseline merge base side base-launcher-predates-result-conversion"],
    readingOutsideDecide: "base-launcher-predates-result-conversion",
    explainsShadowMismatch: true,
    combination: combo("either comparison side is ?/?", stateLess),
    liveReading: {
      branchSide: live(IN(R("?", "?", 1), FAIL1), "preexisting", "fails-at-base-exit-1"),
      mergeBaseSide: live(IN(FAIL1, R("?", "?", 1)), "undetermined", "base-launcher-predates-result-conversion",
        { via: "outside", outsideId: "base-launcher-predates-result-conversion" }),
    },
  }),
  base(5, "intended", "evidence", {
    reason: "The branch side reads SKIP as no records (to table 1); the merge base side reads it as skip-at-base.",
    evidence: ["bin/lib/run-tests-baseline-branch.sh rtb_branch_run_one", "bin/run-tests-baseline merge base side SKIP"],
    dependsOn: ["caseComparison.branchRecordsIgnored"],
    combination: combo("either comparison side is SKIP, or ?/? with exit code 77",
      (r) => r.verdict === "SKIP" || (stateLess(r) && r.exitCode === 77)),
    liveReading: {
      branchSide: live(IN(R("SKIP", "completed", 77), FAIL1, "unchanged", { branchRecordsIgnored: "branch-missing" }),
        "new-case-failure-on-branch", "case-records-missing-on-branch"),
      mergeBaseSide: live(IN(FAIL1, R("SKIP", "completed", 77)), "undetermined", "skip-at-base"),
    },
  }),
  base(6, "intended", "user", {
    reason: "The branch side reads an unknown state as skip; the merge base side reads it as state-<X>-at-base. decide's input has no state string.",
    evidence: ["bin/lib/run-tests-baseline-branch.sh rtb_branch_run_one", "bin/run-tests-baseline merge base side state-<X>-at-base"],
    readingOutsideDecide: "state-<X>-at-base",
    explainsShadowMismatch: true,
    combination: combo("either comparison side is ?/? (unknown state)", stateLess),
    liveReading: {
      branchSide: live(IN(R("?", "?", 77), FAIL1, "unchanged", { branchRecordsIgnored: "branch-missing" }),
        "new-case-failure-on-branch", "case-records-missing-on-branch",
        { via: "decide", rewriteSide: { verdict: "SKIP", termination: "completed" } }),
      mergeBaseSide: live(IN(FAIL1, R("?", "?", 1)), "undetermined", "state-WEIRD-at-base",
        { via: "outside", outsideId: "state-<X>-at-base" }),
    },
  }),
]);

// Whether live read with that comparison side's reading equals the actual live (class, detail).
function readingGives(reading, input, sideKey, liveCD) {
  if (reading.via === "outside") {
    const e = DETAILS_DECIDED_OUTSIDE_DECIDE.find((x) => x.id === reading.outsideId);
    return !!e && e.classes.includes(liveCD.class) && e.detailPattern.test(String(liveCD.detail));
  }
  if (!reading.rewriteSide) return false;
  const rewritten = Object.assign({}, input, { [sideKey]: Object.assign({}, input[sideKey], reading.rewriteSide) });
  try {
    const out = evaluate(DECIDE_ROWS, rewritten).output;
    return out.class === liveCD.class && out.detail === liveCD.detail;
  } catch { return false; }
}

// The record explaining a live/decide mismatch: among records that explain shadow mismatches, the one whose live reading
// on the comparison side matching the combination equals the live (class, detail). null when none.
function findRecordForMismatch(input, liveCD) {
  if (!input || !liveCD) return null;
  return RECORDED_DISCREPANCIES.find((rec) => rec.explainsShadowMismatch && SIDES.some(([sideKey, side]) =>
    isResult(input[sideKey]) && rec.combination.sideMatcher(input[sideKey])
      && readingGives(rec.liveReading[side].reading, input, sideKey, liveCD))) || null;
}

module.exports = { RECORDED_DISCREPANCIES, findRecordForMismatch };
