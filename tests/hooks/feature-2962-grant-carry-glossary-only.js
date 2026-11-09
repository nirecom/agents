"use strict";
// Tests: hooks/workflow-state/glossary-check/grant-carry.js
// Tags: TL1, hooks, workflow-state, glossary, glossary-check, grant-carry, scope:issue-specific
// #2962: a grant carries over a glossary-only change (changed exactly ["glossary"]) when the guard
// says its term's matching fields did not move, and lapses with cause "fields" otherwise; glossary
// changing together with the artifact or the rules lapses it with cause "inputs" as before; a call
// without a guard keeps the pre-#2962 behaviour. staleOutlook gives the same verdict from a record.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const GC = path.resolve(__dirname, "..", "..", "hooks/workflow-state/glossary-check/grant-carry.js");
const gc = () => require(GC);

const FP = (c) => c.repeat(64);
const TERM = "glossary drift";
const I = { artifact: FP("1"), glossary: FP("2"), intent_rows: FP("3"), rules: FP("4") };
const finding = { term: TERM, norm: TERM, variant: "glossary-drift", where: "src/a.js:2" };
const grant = { norm: TERM, fingerprint: FP("a"), reason: "fixture" };
const prev = { fingerprint: FP("a"), inputs: I, findings: [finding], grants: [grant], term_fields: { [TERM]: FP("e") } };
const keysOf = (list, norm) => (list || []).filter((f) => f.norm === norm).map((f) => f.variant);
const termOf = () => TERM;

// carry(changedOver, guard) -> grantCarry over the given input changes; guard omitted when undefined.
function carry(over, guard) {
  const fpResult = { fingerprint: FP("b"), inputs: Object.assign({}, I, over) };
  const args = [prev, fpResult, gc().CARRY_ROLES.check, keysOf, [finding], [finding], termOf];
  if (guard !== undefined) args.push(guard);
  return gc().grantCarry(...args);
}
const carried = (r) => r.carried.length === 1 && r.carried[0].fingerprint === FP("b") && r.expired.length === 0;
const expiredWith = (r, cause) => r.carried.length === 0 && r.expired.length === 1 && r.expired[0].cause === cause;

caseBegin("grantCarry glossary-only branch by the guard", "hooks/workflow-state/glossary-check/grant-carry.js");
test("grantCarry glossary-only branch by the guard", () => {
  const yes = () => true;
  const no = () => false;
  const g = { glossary: FP("8") };
  assert.ok(carried(carry(g, yes)), "glossary-only change, guard true: the grant carries");
  const lapsed = carry(g, no);
  assert.ok(expiredWith(lapsed, "fields"), `glossary-only change, guard false: cause fields (${JSON.stringify(lapsed)})`);
  assert.strictEqual(gc().causeText(lapsed.expired[0]), "its `Identifier` / `Short forms` / heading changed");
  assert.ok(expiredWith(carry({ glossary: FP("8"), artifact: FP("9") }, yes), "inputs"), "artifact + glossary: cause inputs");
  assert.ok(expiredWith(carry({ glossary: FP("8"), rules: FP("9") }, yes), "inputs"), "rules + glossary: cause inputs");
  assert.ok(carried(carry({ artifact: FP("9") }, no)), "artifact-only change carries; the guard is not consulted");
  assert.ok(carried(carry({ rules: FP("9") }, no)), "rules-only change carries; the guard is not consulted");
});
caseEnd();

caseBegin("grantCarry called without a guard keeps the pre-2962 behaviour", "hooks/workflow-state/glossary-check/grant-carry.js");
test("grantCarry called without a guard keeps the pre-2962 behaviour", () => {
  assert.ok(expiredWith(carry({ glossary: FP("8") }), "inputs"), "glossary-only change without a guard: cause inputs");
  assert.ok(carried(carry({ artifact: FP("9") })), "artifact-only change without a guard: carries");
});
caseEnd();

caseBegin("grantCarry glossary-only branch with a new variant of the granted norm", "hooks/workflow-state/glossary-check/grant-carry.js");
test("grantCarry glossary-only branch with a new variant of the granted norm", () => {
  const fpResult = { fingerprint: FP("b"), inputs: Object.assign({}, I, { glossary: FP("8") }) };
  const grown = [finding, Object.assign({}, finding, { variant: "glossarydrift", where: "src/a.js:4" })];
  const r = gc().grantCarry(prev, fpResult, gc().CARRY_ROLES.check, keysOf, [finding], grown, termOf, () => true);
  assert.ok(expiredWith(r, "variants"), `glossary-only change, guard true, a new variant: cause variants (${JSON.stringify(r)})`);
  assert.strictEqual(r.expired[0].norm, TERM);
});
caseEnd();

caseBegin("staleOutlook over a glossary-only change", "hooks/workflow-state/glossary-check/grant-carry.js");
test("staleOutlook over a glossary-only change", () => {
  const roles = gc().CARRY_ROLES.check;
  const same = gc().staleOutlook(prev, ["glossary"], roles, { [TERM]: FP("e") });
  assert.deepStrictEqual(same, { carry: "possible", granted_terms: [TERM] }, "same term fields: carry possible");
  const moved = gc().staleOutlook(prev, ["glossary"], roles, { [TERM]: FP("f") });
  assert.strictEqual(moved.carry, "none", "a moved matching field: carry none");
  assert.deepStrictEqual(moved.granted_terms, [TERM]);
  const both = gc().staleOutlook(prev, ["artifact", "glossary"], roles, { [TERM]: FP("e") });
  assert.strictEqual(both.carry, "none", "glossary with the artifact: carry none");
  const old = Object.assign({}, prev);
  delete old.term_fields;
  assert.strictEqual(gc().staleOutlook(old, ["glossary"], roles, { [TERM]: FP("e") }).carry, "none",
    "a record without term_fields: carry none (fail-safe)");
  assert.strictEqual(gc().staleOutlook(prev, ["artifact"], roles).carry, "possible", "artifact-only without termFields: as before");
});
caseEnd();
