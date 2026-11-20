"use strict";
// Private helper of tests/bin/bin-run-tests-baseline-decide-table.js. Builds decide inputs, holds
// the declared RTB_EXEC_* domain and its parser image, and checks the output shape and the live vocabulary.
// Modules are loaded inside each test. While a module does not exist yet, each test fails with MODULE_NOT_FOUND.
const assert = require("node:assert/strict");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const DECIDE = path.join(ROOT, "bin", "lib", "run-tests-baseline-decide.js");
const PARSER = path.join(ROOT, "bin", "lib", "run-tests-baseline-comparison-side-result.js");
const DISPOSITION = path.join(ROOT, "bin", "workflow", "lib", "run-tests-baseline-evidence", "disposition.js");
const D = () => require(DECIDE);
const P = () => require(PARSER);

const R = (verdict, termination, exitCode, hitKind = "none") => ({ verdict, termination, exitCode, hitKind });
const CD = (cls, detail) => ({ class: cls, detail });
const CMP_FIELDS = ["branchRecordsAsNormal", "branchRecordsAsInterrupted", "branchRecordsIgnored"];
const CMP_VALUES = ["same", "new", "no-records", "branch-missing", "base-missing", "compare-failed"];
const TFC = ["changed", "unchanged", "unknown"];
const SAME = Object.freeze({ branchRecordsAsNormal: "same", branchRecordsAsInterrupted: "same", branchRecordsIgnored: "same" });
const IN = (branchResult, baseResult, testFileChange = "unchanged", cmp = {}) =>
  ({ branchResult, baseResult, testFileChange, caseComparison: Object.assign({}, SAME, cmp) });

// Representative comparison side results (used by the cases of each group).
const K = {
  pass: R("PASS", "completed", 0),
  failNormal: R("FAIL", "completed", 1),
  fail3: R("FAIL", "completed", 3),
  fail124: R("FAIL", "completed", 124),
  fail142: R("FAIL", "completed", 142),
  fail137: R("FAIL", "completed", 137),
  fail143: R("FAIL", "completed", 143),
  skip: R("SKIP", "completed", 77),
  timeout: R("-", "timeout", 124),
  watchdog: R("-", "interrupted-by-outer-watchdog", 137),
  unsupported: R("-", "unsupported", 0),
  unrunnable: R("-", "unrunnable", 1),
  setup: R("-", "launcher-setup-failed", null),
};

const GUARD = "[run-all] command guard hit: node -e x";
const DECOY_LINE = "[run-all] root decoy hit: /tmp/decoy/bin/x";
// The RTB_EXEC_* domain this test declares itself (the rc 2 setup failure is the one combination returned with empty outputs).
function declaredExecProduct() {
  const out = [{ e: { returnCode: 2, RTB_EXEC_RC: "", RTB_EXEC_STATE: "", RTB_EXEC_TIMEDOUT: "0",
    RTB_EXEC_UNSUPPORTED: "0", RTB_EXEC_DECOY: "0", RTB_EXEC_UNRUNNABLE: "0" }, lines: [] }];
  const B = ["0", "1"];
  for (const rc of ["0", "1", "2", "3", "77", "78", "124", "137", "142", "143"])
    for (const st of ["", "PASS", "FAIL", "SKIP", "TIMEOUT", "WEIRD"])
      for (const to of B) for (const us of B) for (const dc of B) for (const ur of B)
        for (const lines of [[], [GUARD], [GUARD, DECOY_LINE]])
          out.push({ e: { returnCode: 0, RTB_EXEC_RC: rc, RTB_EXEC_STATE: st, RTB_EXEC_TIMEDOUT: to,
            RTB_EXEC_UNSUPPORTED: us, RTB_EXEC_DECOY: dc, RTB_EXEC_UNRUNNABLE: ur }, lines });
  return out;
}
const key = (r) => (r === null ? "null" : JSON.stringify([r.verdict, r.termination, r.exitCode, r.hitKind]));
let imageCache;
// The image of the declared domain through the parser (deduplicated).
function parserImage() {
  if (!imageCache) {
    const m = new Map();
    for (const { e, lines } of declaredExecProduct()) {
      const r = P().parseComparisonSideResult(e, lines);
      m.set(key(r), r);
    }
    imageCache = [...m.values()];
  }
  return imageCache;
}

// The live (class, detail) vocabulary. decide's { class, detail } must be a subset of it.
const N = "(0|[1-9][0-9]*)";
const LIVE_VOCAB = [
  ["broken", /^passes-at-base$/],
  ["preexisting", new RegExp(`^fails-at-base-exit-${N}$`)],
  ["new-case-failure-on-branch",
    new RegExp(`^(case-records-missing-on-branch|case-records-missing-at-base|fails-at-base-exit-${N}-new-lines)$`)],
  ["file-verdict-preexisting", /^(no-case-records|test-file-changed)$/],
  ["undetermined", new RegExp("^(ambiguous-exit-(124|137|142|143)|root-decoy-hit-on-branch|root-decoy-hit-at-base|" +
    "compare-failed|timeout-at-base|unsupported-at-base|unrunnable-at-base|skip-at-base|exec-setup-failed)$")],
];
const inLiveVocab = (o) => LIVE_VOCAB.some(([c, re]) => c === o.class && typeof o.detail === "string" && re.test(o.detail));

// Checks that the output is exactly one of the three shapes.
function checkOutputForm(out, label) {
  assert.ok(out && typeof out === "object", `${label}: output is an object`);
  const keys = Object.keys(out).sort().join(",");
  if (keys === "class,detail") {
    assert.ok(inLiveVocab(out), `${label}: ${JSON.stringify(out)} is in the live vocabulary`);
  } else if (keys === "needsBaseResult") {
    assert.equal(out.needsBaseResult, true, `${label}: needsBaseResult is true`);
  } else if (keys === "decidedOutsideDecide") {
    const ids = D().DETAILS_DECIDED_OUTSIDE_DECIDE.map((x) => x.id);
    assert.ok(ids.includes(out.decidedOutsideDecide), `${label}: ${out.decidedOutsideDecide} is an id of the outside-decide list`);
  } else {
    assert.fail(`${label}: the output is none of the three shapes: ${JSON.stringify(out)}`);
  }
}

// Calls decide and listMatchingDecideRows together, and checks there is exactly one row and the output shape.
function decideOne(input, label) {
  const rows = D().listMatchingDecideRows(input);
  assert.ok(Array.isArray(rows), `${label}: listMatchingDecideRows is an array`);
  assert.equal(rows.length, 1, `${label}: exactly one matching row (actual ${rows.map((r) => r && r.id).join(",")})`);
  const out = D().decide(input);
  checkOutputForm(out, label);
  return out;
}

module.exports = { ROOT, DECIDE, PARSER, DISPOSITION, D, P, R, CD, IN, K, SAME, CMP_FIELDS, CMP_VALUES, TFC,
  GUARD, DECOY_LINE, declaredExecProduct, parserImage, key, LIVE_VOCAB, inLiveVocab, checkOutputForm, decideOne };
