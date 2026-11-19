"use strict";
// The decide table: each row is plain data { id, group, discrepancyId?, fieldRead?, when, output }.
// when lists the allowed values per feature; rows are mutually exclusive without relying on order (exactly one matches).
// output is { class, detail } ({feature name} in detail is the input value) or a special output. The reading order
// follows the current bin/run-tests-baseline and bin/lib/run-tests-baseline-{branch,classify}.sh.
const { CMP_FIELDS, CMP_VALUES, TFC_VALUES } = require("./evaluate");
const { C, IN, NOT_IN, and, or, sidePredicates, KILL, INTERRUPT, AMBIGUOUS } = require("./when-builder");

const b = sidePredicates("branchResult");
const s = sidePredicates("baseResult");
const ALL_AMBIGUOUS_OR_SPECIAL = [0, 77, ...AMBIGUOUS];

// Kinds of branch result. A state-less result is read by rc (discrepancy 2).
const BK = {
  setup: b.setup,
  pass: b.verdict(["PASS"]),
  passStateLess: and(b.stateLess, b.rcIn([0])),
  kill: and(b.verdict(["FAIL"]), b.rcIn(KILL)),
  killStateLess: and(b.stateLess, b.rcIn(KILL)),
  timeout: b.timeout,
  noRecords: b.unrunnable,
  decoy: b.decoy,
  IGNORED: or(b.unsupported, b.verdict(["SKIP"]), and(b.stateLess, b.rcIn([77]))),
  INTERRUPTED: or(and(b.verdict(["FAIL"]), b.rcIn(INTERRUPT)), and(b.stateLess, b.rcIn(INTERRUPT))),
  NORMAL: or(and(b.verdict(["FAIL"]), b.rcNotIn(AMBIGUOUS)), and(b.stateLess, b.rcNotIn(ALL_AMBIGUOUS_OR_SPECIAL))),
};
const KIND_OF_FIELD = { branchRecordsAsNormal: BK.NORMAL, branchRecordsAsInterrupted: BK.INTERRUPTED, branchRecordsIgnored: BK.IGNORED };
const TABLE_KINDS = or(BK.timeout, BK.noRecords, BK.decoy, BK.IGNORED, BK.INTERRUPTED, BK.NORMAL);

// How the merge base side is read (order of the case statement in bin/run-tests-baseline).
const PRESENT = C({ baseResult: IN(["present"]) });
const BASE = {
  pass: or(s.verdict(["PASS"]), and(s.stateLess, s.rcIn([0]))),
  fails: or(and(s.verdict(["FAIL"]), s.rcNotIn(KILL)), and(s.stateLess, s.rcNotIn(ALL_AMBIGUOUS_OR_SPECIAL))),
};
const UNCHANGED = C({ testFileChange: IN(["unchanged"]) });
const CHANGED = C({ testFileChange: NOT_IN(["unchanged"]) });

const CD = (cls, detail) => ({ class: cls, detail });
const U = (detail) => CD("undetermined", detail);
const MISSING_ON_BRANCH = CD("new-case-failure-on-branch", "case-records-missing-on-branch");
const BASE_EXIT = "fails-at-base-exit-{baseResult.exitCode}";

const row = (id, group, when, output, extra) => Object.assign({ id, group }, extra || {}, { when: { anyOf: when }, output });
const D2 = { discrepancyId: "discrepancy-2" };
// Groups ii / iii / iv: the branch result is a kind that proceeds to table 1, and a merge base side result exists.
const atBase = (...ps) => and(TABLE_KINDS, PRESENT, ...ps);

// Discrepancy 1 (interrupted records) reads the AsInterrupted field; discrepancy 5 (no records) reads the Ignored field.
const FIELD_DISCREPANCY = { branchRecordsAsInterrupted: "discrepancy-1", branchRecordsIgnored: "discrepancy-5" };
const TABLE1 = {
  "compare-failed": [(f) => C({ [f]: IN(["compare-failed"]) }), U("compare-failed")],
  "test-file-changed": [(f) => and(CHANGED, C({ [f]: NOT_IN(["compare-failed"]) })), CD("file-verdict-preexisting", "test-file-changed")],
  same: [(f) => and(UNCHANGED, C({ [f]: IN(["same"]) })), CD("preexisting", BASE_EXIT)],
  new: [(f) => and(UNCHANGED, C({ [f]: IN(["new"]) })), CD("new-case-failure-on-branch", `${BASE_EXIT}-new-lines`)],
  "no-records": [(f) => and(UNCHANGED, C({ [f]: IN(["no-records"]) })), CD("file-verdict-preexisting", "no-case-records")],
  "branch-missing": [(f) => and(UNCHANGED, C({ [f]: IN(["branch-missing"]) })), MISSING_ON_BRANCH],
  "base-missing": [(f) => and(UNCHANGED, C({ [f]: IN(["base-missing"]) })), CD("new-case-failure-on-branch", "case-records-missing-at-base")],
};

function table1Row(field, outcome) {
  const [when, output] = TABLE1[outcome];
  const extra = Object.assign({ fieldRead: field }, FIELD_DISCREPANCY[field] ? { discrepancyId: FIELD_DISCREPANCY[field] } : {});
  return row(`iv-${field}-${outcome}`, "iv", atBase(KIND_OF_FIELD[field], BASE.fails, when(`caseComparison.${field}`)), output, extra);
}

const DECIDE_ROWS = Object.freeze([
  row("i-branch-setup-failed", "i", BK.setup, U("exec-setup-failed")),
  row("i-branch-pass", "i", BK.pass, { decidedOutsideDecide: "exit-<N>-then-pass" }),
  row("i-branch-pass-state-less", "i", BK.passStateLess, { decidedOutsideDecide: "exit-<N>-then-pass" }, D2),
  row("i-branch-kill", "i", BK.kill, U("ambiguous-exit-{branchResult.exitCode}")),
  row("i-branch-kill-state-less", "i", BK.killStateLess, U("ambiguous-exit-{branchResult.exitCode}"), D2),
  row("i-needs-base-result", "i", and(TABLE_KINDS, C({ baseResult: IN(["absent"]) })), { needsBaseResult: true }),
  row("ii-base-setup", "ii", atBase(s.setup), U("exec-setup-failed")),
  row("ii-base-timeout", "ii", atBase(s.timeout), U("timeout-at-base")),
  row("ii-base-unsupported", "ii", atBase(s.unsupported), U("unsupported-at-base")),
  row("ii-base-decoy", "ii", atBase(s.decoy), U("root-decoy-hit-at-base"), { discrepancyId: "discrepancy-3" }),
  row("ii-base-unrunnable", "ii", atBase(s.unrunnable), U("unrunnable-at-base")),
  row("ii-base-skip", "ii", atBase(s.verdict(["SKIP"])), U("skip-at-base"), { discrepancyId: "discrepancy-5" }),
  row("ii-base-skip-state-less", "ii", atBase(s.stateLess, s.rcIn([77])), U("skip-at-base"), D2),
  row("ii-base-kill", "ii", atBase(s.verdict(["FAIL"]), s.rcIn(KILL)), U("ambiguous-exit-{baseResult.exitCode}")),
  row("ii-base-ambiguous-state-less", "ii", atBase(s.stateLess, s.rcIn(AMBIGUOUS)), U("ambiguous-exit-{baseResult.exitCode}"), D2),
  // `rtb_cls_base_pass`: ignores a branch timeout.
  row("ii-base-pass-broken", "ii", atBase(or(BK.timeout, BK.IGNORED, BK.INTERRUPTED, BK.NORMAL), BASE.pass), CD("broken", "passes-at-base")),
  row("iii-branch-no-records-or-timeout", "iii", atBase(or(BK.noRecords, BK.timeout), BASE.fails), MISSING_ON_BRANCH),
  row("iii-branch-decoy-unchanged", "iii", atBase(BK.decoy, BASE.fails, UNCHANGED), U("root-decoy-hit-on-branch")),
  row("iii-branch-decoy-changed", "iii", atBase(BK.decoy, BASE.fails, CHANGED), MISSING_ON_BRANCH),
  row("iii-branch-no-records-base-pass", "iii", atBase(or(BK.noRecords, BK.decoy), BASE.pass), MISSING_ON_BRANCH),
  ...CMP_FIELDS.flatMap((f) => Object.keys(TABLE1).map((o) => table1Row(f, o))),
]);

const R = (verdict, termination, exitCode, hitKind) => ({ verdict, termination, exitCode, hitKind });
const HIT_KINDS = ["none", "command-guard-hit-only", "root-decoy-or-worktree-change"];
// Exit codes: the values whose reading differs, plus representative others (1, 2, 3, 78).
const EXIT_CODES = [0, 1, 2, 3, 77, 78, 124, 137, 142, 143];
const SHAPES = [["-", "timeout"], ["-", "interrupted-by-outer-watchdog"], ["-", "unsupported"], ["-", "unrunnable"],
  ["PASS", "completed"], ["FAIL", "completed"], ["SKIP", "completed"], ["?", "?"]];

function* enumerateComparisonSideResultDomain() {
  for (const h of HIT_KINDS) yield R("-", "launcher-setup-failed", null, h);
  for (const rc of EXIT_CODES) for (const h of HIT_KINDS) for (const [v, t] of SHAPES) yield R(v, t, rc, h);
}

const SAME = { branchRecordsAsNormal: "same", branchRecordsAsInterrupted: "same", branchRecordsIgnored: "same" };
const INPUT = (branchResult, baseResult, testFileChange, caseComparison) => ({ branchResult, baseResult, testFileChange, caseComparison });

// The product of comparison side results (comparison same, unchanged), plus table-1 representatives x change status x case comparison.
// The representatives include a decoy branch result so the changed-decoy row is also reached.
function* enumerateDecideInputDomain() {
  const all = [...enumerateComparisonSideResultDomain()];
  for (const br of all) for (const base of [null, ...all]) yield INPUT(br, base, "unchanged", Object.assign({}, SAME));
  const reps = [R("FAIL", "completed", 1, "none"), R("FAIL", "completed", 124, "none"), R("SKIP", "completed", 77, "none"),
    R("FAIL", "completed", 1, "command-guard-hit-only"), R("FAIL", "completed", 1, "root-decoy-or-worktree-change")];
  const bases = [R("FAIL", "completed", 1, "none"), R("FAIL", "completed", 124, "none"), R("PASS", "completed", 0, "none")];
  for (const br of reps) for (const base of bases) for (const tfc of TFC_VALUES) {
    for (const a of CMP_VALUES) for (const i of CMP_VALUES) for (const g of CMP_VALUES) {
      yield INPUT(br, base, tfc, { branchRecordsAsNormal: a, branchRecordsAsInterrupted: i, branchRecordsIgnored: g });
    }
  }
}

module.exports = { DECIDE_ROWS, enumerateComparisonSideResultDomain, enumerateDecideInputDomain };
