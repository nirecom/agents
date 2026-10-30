"use strict";
// Tests: hooks/workflow-gate/review-scope-delta.js
// Tags: workflow, gate, review-tests, scope-delta, covering-test, large-change, pure-function, TL1, scope:issue-specific
// #2327: decideReviewScope(recorded, current, headerTargets) on the impl-changed path. A changed
// implementation is re-reviewed through its covering tests (staged tests whose Tests header names
// it exactly); no covering test, a bad header map, or a review set above
// LARGE_CHANGE_REVIEW_RATIO of the staged tests falls back to full. The module is required inside
// each test, so a missing module or export fails every case with its own message.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const DELTA = path.join(__dirname, "..", "..", "hooks", "workflow-gate", "review-scope-delta.js");
const mod = () => require(DELTA);
const drs = (recorded, current, targets) => mod().decideReviewScope(recorded, current, targets);
const rec = (files) => ({ v: 1, files });
const cur = (files) => ({ ok: true, files });

// Staged test files a..n with fixed OIDs; `changed` names get a new OID in `after`.
function tests(names, changed) {
  const before = {};
  const after = {};
  for (const n of names) {
    before[`tests/${n}.sh`] = `${n}-old`;
    after[`tests/${n}.sh`] = (changed || []).includes(n) ? `${n}-new` : `${n}-old`;
  }
  return { before, after };
}
const T = (n) => `tests/${n}.sh`;
const IMPL = "hooks/impl.js";

function assertFull(r, reason, review) {
  assert.strictEqual(r.scope, "full", JSON.stringify(r));
  assert.strictEqual(r.reason, reason, JSON.stringify(r));
  assert.deepStrictEqual(r.review, review);
  assert.deepStrictEqual(r.inventory, []);
  assert.deepStrictEqual(r.deleted, []);
}

caseBegin("D6-impl-changed-covering-delta", "hooks/workflow-gate/review-scope-delta.js");
test("D6: an implementation change is a delta over its covering test", () => {
  const t = tests(["a", "b", "c"]);
  const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }),
    { [T("a")]: [IMPL], [T("b")]: [], [T("c")]: [] });
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "impl-changed");
  assert.deepStrictEqual(r.review, [T("a")]);
  assert.deepStrictEqual(r.inventory, [T("b"), T("c")]);
  assert.deepStrictEqual(r.deleted, []);
  assert.ok(r.sources.includes(IMPL), JSON.stringify(r.sources));
});
caseEnd();

caseBegin("P1-P2-impl-uncovered", "hooks/workflow-gate/review-scope-delta.js");
test("P1: no staged test declares the changed implementation → full impl-uncovered", () => {
  const t = tests(["a", "b"]);
  const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }),
    { [T("a")]: [], [T("b")]: ["hooks/other.js"] });
  assertFull(r, "impl-uncovered", [T("a"), T("b")]);
});
test("P2: two implementations changed, only one covered → full impl-uncovered", () => {
  const t = tests(["a", "b", "c", "d"]);
  const r = drs(rec({ ...t.before, "hooks/x.js": "x1", "hooks/y.js": "y1" }),
    cur({ ...t.after, "hooks/x.js": "x2", "hooks/y.js": "y2" }),
    { [T("a")]: ["hooks/x.js"], [T("b")]: [], [T("c")]: [], [T("d")]: [] });
  assertFull(r, "impl-uncovered", [T("a"), T("b"), T("c"), T("d")]);
});
caseEnd();

caseBegin("P3-header-map-unavailable", "hooks/workflow-gate/review-scope-delta.js");
test("P3: an absent or malformed header map on the impl path → full header-map-unavailable", () => {
  const t = tests(["a", "b", "c"]);
  const good = { [T("a")]: [IMPL], [T("b")]: [], [T("c")]: [] };
  const variants = {
    null: null,
    undefined: undefined,
    array: [[T("a"), [IMPL]]],
    "value-not-array": { ...good, [T("a")]: IMPL },
    "element-not-string": { ...good, [T("a")]: [IMPL, 7] },
    "staged-test-key-missing": { [T("a")]: [IMPL], [T("b")]: [] },
  };
  for (const [name, targets] of Object.entries(variants)) {
    const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }), targets);
    assert.strictEqual(r.scope, "full", `${name}: ${JSON.stringify(r)}`);
    assert.strictEqual(r.reason, "header-map-unavailable", `${name}: ${JSON.stringify(r)}`);
    assert.deepStrictEqual(r.review, [T("a"), T("b"), T("c")], name);
    assert.deepStrictEqual(r.inventory, [], name);
  }
  // Control: the same fixture with the well-formed map is a delta.
  const ok = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }), good);
  assert.strictEqual(ok.scope, "delta", JSON.stringify(ok));
});
caseEnd();

caseBegin("P4-tests-only-ignores-map", "hooks/workflow-gate/review-scope-delta.js");
test("P4: a tests-only change never reads the header map", () => {
  const t = tests(["a", "b", "c"], ["a"]);
  for (const targets of [null, undefined, "broken"]) {
    const r = drs(rec({ ...t.before, [IMPL]: "same" }), cur({ ...t.after, [IMPL]: "same" }), targets);
    assert.strictEqual(r.scope, "delta", JSON.stringify(r));
    assert.strictEqual(r.reason, "tests-only");
    assert.deepStrictEqual(r.review, [T("a")]);
  }
});
caseEnd();

caseBegin("P5-P6-review-union", "hooks/workflow-gate/review-scope-delta.js");
test("P5: a covering test that also changed appears once; review is sorted", () => {
  const t = tests(["a", "b", "c", "d", "e"], ["d"]);
  const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }),
    { [T("a")]: [IMPL], [T("b")]: [], [T("c")]: [], [T("d")]: [IMPL], [T("e")]: [] });
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "impl-changed");
  assert.deepStrictEqual(r.review, [T("a"), T("d")]);
  assert.deepStrictEqual(r.inventory, [T("b"), T("c"), T("e")]);
});
test("P6: review is changed tests plus covering tests; the rest is inventory", () => {
  const t = tests(["a", "b", "c", "d", "e", "f"], ["b"]);
  const targets = Object.fromEntries(Object.keys(t.after).map((p) => [p, []]));
  targets[T("e")] = ["bin/unrelated.sh", IMPL];
  const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }), targets);
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "impl-changed");
  assert.deepStrictEqual(r.review, [T("b"), T("e")]);
  assert.deepStrictEqual(r.inventory, [T("a"), T("c"), T("d"), T("f")]);
  assert.deepStrictEqual(r.deleted, []);
});
caseEnd();

caseBegin("P15-P16-multi-impl-and-added-test", "hooks/workflow-gate/review-scope-delta.js");
test("P15: two changed impls, each with its own covering test → delta over both, once each", () => {
  const t = tests(["a", "b", "c", "d", "e", "f"]);
  const r = drs(rec({ ...t.before, "hooks/x.js": "x1", "hooks/y.js": "y1" }),
    cur({ ...t.after, "hooks/x.js": "x2", "hooks/y.js": "y2" }),
    { [T("a")]: ["hooks/x.js"], [T("b")]: [], [T("c")]: ["hooks/y.js"], [T("d")]: [], [T("e")]: [], [T("f")]: [] });
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "impl-changed");
  assert.deepStrictEqual(r.review, [T("a"), T("c")]);
  assert.deepStrictEqual(r.inventory, [T("b"), T("d"), T("e"), T("f")]);
  assert.deepStrictEqual(r.deleted, []);
});
test("P16: an impl change plus a newly added (non-covering) test reviews both", () => {
  const t = tests(["a", "b", "c", "d", "e"]);
  const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [T("new")]: "n", [IMPL]: "new" }),
    { [T("a")]: [], [T("b")]: [IMPL], [T("c")]: [], [T("d")]: [], [T("e")]: [], [T("new")]: ["bin/other.sh"] });
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "impl-changed");
  assert.deepStrictEqual(r.review, [T("b"), T("new")]);
  assert.deepStrictEqual(r.inventory, [T("a"), T("c"), T("d"), T("e")]);
  assert.deepStrictEqual(r.deleted, []);
});
caseEnd();

caseBegin("P7-P9-large-change-threshold", "hooks/workflow-gate/review-scope-delta.js");
test("P9: LARGE_CHANGE_REVIEW_RATIO is exported and is 0.5", () => {
  assert.strictEqual(mod().LARGE_CHANGE_REVIEW_RATIO, 0.5);
});
test("P7: impl path — 2/4 stays delta, 3/5 is full large-change", () => {
  const t4 = tests(["a", "b", "c", "d"], ["a"]);
  const m4 = { [T("a")]: [], [T("b")]: [IMPL], [T("c")]: [], [T("d")]: [] };
  const r4 = drs(rec({ ...t4.before, [IMPL]: "old" }), cur({ ...t4.after, [IMPL]: "new" }), m4);
  assert.strictEqual(r4.scope, "delta", JSON.stringify(r4));
  assert.strictEqual(r4.reason, "impl-changed");
  assert.deepStrictEqual(r4.review, [T("a"), T("b")]);
  const t5 = tests(["a", "b", "c", "d", "e"], ["a", "b"]);
  const m5 = { [T("a")]: [], [T("b")]: [], [T("c")]: [IMPL], [T("d")]: [], [T("e")]: [] };
  const r5 = drs(rec({ ...t5.before, [IMPL]: "old" }), cur({ ...t5.after, [IMPL]: "new" }), m5);
  assertFull(r5, "large-change", [T("a"), T("b"), T("c"), T("d"), T("e")]);
});
test("P8: tests-only path — 2/4 delta, 3/5 and 1/1 full large-change", () => {
  const t4 = tests(["a", "b", "c", "d"], ["a", "b"]);
  const r4 = drs(rec(t4.before), cur(t4.after), null);
  assert.strictEqual(r4.scope, "delta", JSON.stringify(r4));
  assert.strictEqual(r4.reason, "tests-only");
  const t5 = tests(["a", "b", "c", "d", "e"], ["a", "b", "c"]);
  assertFull(drs(rec(t5.before), cur(t5.after), null), "large-change", Object.keys(t5.after).sort());
  const t1 = tests(["a"], ["a"]);
  assertFull(drs(rec(t1.before), cur(t1.after), null), "large-change", [T("a")]);
});
caseEnd();

caseBegin("P10-deleted-impl-and-test", "hooks/workflow-gate/review-scope-delta.js");
test("P10: a deleted implementation is covered by name; deleted lists only the deleted test", () => {
  const t = tests(["a", "b", "c", "d"]);
  const r = drs(rec({ ...t.before, [T("gone")]: "g", "hooks/old.js": "x" }), cur({ ...t.after }),
    { [T("a")]: ["hooks/old.js"], [T("b")]: [], [T("c")]: [], [T("d")]: [] });
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "impl-changed");
  assert.deepStrictEqual(r.review, [T("a")]);
  assert.deepStrictEqual(r.deleted, [T("gone")]);
  assert.deepStrictEqual(r.inventory, [T("b"), T("c"), T("d")]);
  assert.ok(!r.sources.includes("hooks/old.js"), JSON.stringify(r.sources));
});
caseEnd();

caseBegin("P11-P12-uncovered-edges", "hooks/workflow-gate/review-scope-delta.js");
test("P11: an impl change with no staged test → full impl-uncovered with an empty review", () => {
  const r = drs(rec({ [IMPL]: "old" }), cur({ [IMPL]: "new" }), {});
  assertFull(r, "impl-uncovered", []);
});
test("P12: only an exact token covers — ./-prefixed and directory tokens do not", () => {
  const t = tests(["a", "b", "c"]);
  for (const token of ["./hooks/impl.js", "hooks/", "hooks"]) {
    const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }),
      { [T("a")]: [token], [T("b")]: [], [T("c")]: [] });
    assert.strictEqual(r.scope, "full", `${token}: ${JSON.stringify(r)}`);
    assert.strictEqual(r.reason, "impl-uncovered", token);
  }
});
caseEnd();

caseBegin("P13-P14-unchanged-paths", "hooks/workflow-gate/review-scope-delta.js");
test("P13: no-record and explicit-rereview are unaffected by a null header map", () => {
  const files = { [T("a")]: "a", [IMPL]: "i" };
  assertFull(drs(null, cur(files), null), "no-record", [T("a")]);
  assertFull(drs(rec(files), cur(files), null), "explicit-rereview", [T("a")]);
});
test("P14: changes to excluded paths (docs/, CHANGELOG.md) are not implementation changes", () => {
  const t = tests(["a", "b", "c"], ["a"]);
  const r = drs(rec({ ...t.before, "docs/guide.md": "d1", "CHANGELOG.md": "c1" }),
    cur({ ...t.after, "docs/guide.md": "d2", "CHANGELOG.md": "c2" }), null);
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "tests-only");
  assert.deepStrictEqual(r.review, [T("a")]);
});
caseEnd();

caseBegin("P17-shared-impl-multiple-covering", "hooks/workflow-gate/review-scope-delta.js");
test("P17: every unchanged staged test naming the one changed impl is reviewed, sorted", () => {
  const t = tests(["a", "b", "c", "d", "e", "f"]);
  const targets = Object.fromEntries(Object.keys(t.after).map((p) => [p, ["bin/other.sh"]]));
  targets[T("d")] = [IMPL];
  targets[T("a")] = ["bin/other.sh", IMPL];
  const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }), targets);
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "impl-changed");
  assert.deepStrictEqual(r.review, [T("a"), T("d")]);
  assert.deepStrictEqual(r.inventory, [T("b"), T("c"), T("e"), T("f")]);
  assert.deepStrictEqual(r.deleted, []);
});
test("P17: a third covering test is included too (3/6 is exactly the ratio, still delta)", () => {
  const t = tests(["a", "b", "c", "d", "e", "f"]);
  const targets = Object.fromEntries(Object.keys(t.after).map((p) => [p, []]));
  for (const n of ["f", "a", "d"]) targets[T(n)] = [IMPL];
  const r = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }), targets);
  assert.strictEqual(r.scope, "delta", JSON.stringify(r));
  assert.strictEqual(r.reason, "impl-changed");
  assert.deepStrictEqual(r.review, [T("a"), T("d"), T("f")]);
  assert.deepStrictEqual(r.inventory, [T("b"), T("c"), T("e")]);
  // Control: a fourth covering test pushes the review over half → full large-change.
  targets[T("b")] = [IMPL];
  const big = drs(rec({ ...t.before, [IMPL]: "old" }), cur({ ...t.after, [IMPL]: "new" }), targets);
  assertFull(big, "large-change", Object.keys(t.after).sort());
});
caseEnd();
