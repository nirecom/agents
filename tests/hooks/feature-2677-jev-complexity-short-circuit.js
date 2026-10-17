"use strict";
// Tests: hooks/lib/jev/two-stage/gate.js, hooks/lib/jev/two-stage/query.js, hooks/lib/jev/registry.js, bin/workflow/lib/jev-complexity-adapter.js
// Tags: TL2, hooks, jev, two-stage, complexity-gate, short-circuit, decisive, threshold, routing, mock-server, scope:issue-specific
// #2677: complexity-judge adopts a signal at p>=0.7, never adopts its absence (false: null),
// and short-circuits on adopted-true signals only when they already decide "high" at every
// routing stage the judgment feeds (the adapter's decidesAtStage, handed as hooks.decides).
// S3 alone is not decisive at complexity / outline / detail, so it still delegates there.
// TL3 gap (what this test does NOT catch):
// - the live Jev service's probability calibration against these thresholds
// Closest-to-action mitigation: the real jev-judge CLI against the echo mock server.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");
const J = require("./feature-2677-jev/jj-fixture");

const GATE_JS = path.join(J.REPO, "hooks", "lib", "jev", "two-stage", "gate.js");
const REGISTRY_JS = path.join(J.REPO, "hooks", "lib", "jev", "registry.js");
const ADAPTER_JS = path.join(J.REPO, "bin", "workflow", "lib", "jev-complexity-adapter.js");
const ALL3 = "s2_architecture,s3_security,s5_breaking";

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2677-sc-"));
let mock = null;
after(() => {
  if (mock) mock.stop();
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

caseBegin("gate-decides-hook", "hooks/lib/jev/two-stage/gate.js");
const { applyGate } = require(GATE_JS);
const POLICY = { confidence_threshold_by_answer: { true: 0.7, false: null }, short_circuit_answer: true };
// a true-adopted, b held (uncertain), c held (false side null: never adopted).
const ITEMS = { a: { p: 0.95 }, b: { p: 0.5 }, c: { p: 0.01 } };
// spy(fn): a decides hook that records every key set it is handed.
const spy = (fn) => { const calls = []; const decides = (ks) => { calls.push(ks.slice().sort()); return fn(ks); }; return { calls, decides }; };
test("no hooks, sc true: the value-based short circuit stays (backward compatible)", () => {
  const g = applyGate(ITEMS, POLICY);
  assert.strictEqual(g.short_circuited, true);
  assert.strictEqual(g.result, "final");
  assert.deepStrictEqual(g.unjudged, ["b", "c"]);
});
test("decides always false: no short circuit, held keys delegated, decides handed the true-adopted keys", () => {
  const h = spy(() => false);
  const g = applyGate(ITEMS, POLICY, { decides: h.decides });
  assert.deepStrictEqual(h.calls, [["a"]], "decides is handed exactly the keys adopted with value === sc");
  assert.strictEqual(g.short_circuited, false);
  assert.deepStrictEqual(g.delegated, ["b", "c"]);
  assert.deepStrictEqual(g.unjudged, []);
  assert.strictEqual(g.result, "need-subagent");
  assert.deepStrictEqual(g.adopted, { a: true });
});
test("decides true: short circuit, held keys unjudged, result final", () => {
  const h = spy(() => true);
  const g = applyGate(ITEMS, POLICY, { decides: h.decides });
  assert.deepStrictEqual(h.calls, [["a"]]);
  assert.strictEqual(g.short_circuited, true);
  assert.deepStrictEqual(g.unjudged, ["b", "c"]);
  assert.deepStrictEqual(g.delegated, []);
  assert.strictEqual(g.result, "final");
});
test("decides throws: treated as false (no short circuit, held keys delegated)", () => {
  const g = applyGate(ITEMS, POLICY, { decides: () => { throw new Error("routing table unavailable"); } });
  assert.strictEqual(g.short_circuited, false);
  assert.deepStrictEqual(g.delegated, ["b", "c"]);
  assert.strictEqual(g.result, "need-subagent");
});
test("no adopted key matches sc: decides is never called, no short circuit", () => {
  const h = spy(() => true);
  const g = applyGate({ b: { p: 0.5 }, c: { p: 0.01 } }, POLICY, { decides: h.decides });
  assert.deepStrictEqual(h.calls, []);
  assert.strictEqual(g.short_circuited, false);
  assert.deepStrictEqual(g.delegated, ["b", "c"]);
});
caseEnd();

caseBegin("adapter-decides-at-stage", "bin/workflow/lib/jev-complexity-adapter.js");
const adapter = require(ADAPTER_JS);
const K = (...ids) => ids.map((id) => adapter.questionKey(id));
const S2 = "S2-architecture";
const S3 = "S3-security";
const S5 = "S5-breaking";
// [stage, S2, S3, S5, S2+S3]
const DECISIVE = [
  ["complexity", true, false, true, true],
  ["outline", true, false, true, true],
  ["detail", true, false, true, true],
  ["write-tests", true, true, true, true],
  ["write-code", true, true, true, true],
];
test("decidesAtStage is exported as a function", () => {
  assert.strictEqual(typeof adapter.decidesAtStage, "function");
});
for (const [stage, s2, s3, s5, s23] of DECISIVE) {
  test(`decidesAtStage(${stage}): S2 ${s2}, S3 ${s3}, S5 ${s5}, S2+S3 ${s23}`, () => {
    assert.strictEqual(adapter.decidesAtStage(stage, K(S2)), s2, "S2");
    assert.strictEqual(adapter.decidesAtStage(stage, K(S3)), s3, "S3");
    assert.strictEqual(adapter.decidesAtStage(stage, K(S5)), s5, "S5");
    assert.strictEqual(adapter.decidesAtStage(stage, K(S2, S3)), s23, "S2+S3");
  });
}
test("decidesAtStage is false for an empty set, an unknown stage and an unknown key", () => {
  assert.strictEqual(adapter.decidesAtStage("complexity", []), false, "empty set");
  assert.strictEqual(adapter.decidesAtStage("cos1", K(S2)), false, "stage cos1");
  assert.strictEqual(adapter.decidesAtStage("unknown", K(S2)), false, "stage unknown");
  assert.strictEqual(adapter.decidesAtStage("complexity", ["s9_bogus"]), false, "unknown key");
});
caseEnd();

caseBegin("registry-complexity-threshold", "hooks/lib/jev/registry.js");
const { REGISTRY } = require(REGISTRY_JS);
test("complexity-judge: threshold {true:0.7,false:null}, short_circuit_answer true", () => {
  const e = REGISTRY["complexity-judge"];
  assert.deepStrictEqual(JSON.parse(JSON.stringify(e.confidence_threshold_by_answer)), { true: 0.7, false: null });
  assert.strictEqual(e.short_circuit_answer, true);
});
test("every point short-circuiting on true has an adapter with decidesAtStage; the skip adapters have none", () => {
  const sc = Object.entries(REGISTRY).filter(([, e]) => e.short_circuit_answer === true);
  assert.ok(sc.some(([p]) => p === "complexity-judge"), "complexity-judge is among the sc-true points");
  for (const [p, e] of sc) {
    assert.strictEqual(typeof require(e.adapter).decidesAtStage, "function", `${p}: adapter exports decidesAtStage`);
  }
  for (const p of ["outline-skip", "detail-skip"]) {
    assert.ok(REGISTRY[p], `${p} is registered`);
    assert.strictEqual(require(REGISTRY[p].adapter).decidesAtStage, undefined, `${p}: value-based, no decidesAtStage`);
  }
});
caseEnd();

caseBegin("cli-complexity-short-circuit", "hooks/lib/jev/two-stage/query.js");
mock = J.startMock(path.join(ROOT, "mock"));
const STAGE_FILES = {
  complexity: {},
  outline: { outline: true },
  detail: { outline: true },
  "write-tests": { outline: true, detail: true },
  "write-code": { outline: true, detail: true, writeCode: "bin/report\n" },
};
let seq = 0;
// run(stage, defaultP, keyProbs): query, then finalize when the query is final. -> {fx, q, f, ticket, rec}.
function run(stage, defaultP, keyProbs) {
  seq += 1;
  const fx = J.newFx(ROOT, `sc-${seq}-${stage}`, STAGE_FILES[stage]);
  mock.probs(defaultP, keyProbs);
  const q = J.cxQuery(fx, mock, stage);
  assert.strictEqual(q.status, 0, `query exit 0 (stderr: ${q.stderr})`);
  assert.strictEqual(mock.count("systemone"), 1, `premise: Jev asked once at ${stage}`);
  const ticket = q.kv("TICKET");
  const f = q.kv("RESULT") === "final" ? J.finalize(fx, mock, ticket) : null;
  return { fx, q, f, ticket, rec: f ? J.decision(fx, ticket) : null };
}
test("complexity, S2 p=0.75 (others 0.5): RESULT=final, nothing delegated, unjudged recorded apart", () => {
  const r = run("complexity", 0.5, { [S2]: 0.75 });
  assert.strictEqual(r.q.kv("RESULT"), "final", `query stdout: ${r.q.stdout}`);
  assert.strictEqual(r.q.kv("DELEGATED"), "-");
  assert.strictEqual(r.f.kv("SIGNALS_CSV"), "S2-architecture");
  assert.strictEqual(r.rec.short_circuited, true);
  assert.deepStrictEqual(r.rec.unjudged_keys.slice().sort(), ["s3_security", "s5_breaking"]);
  assert.deepStrictEqual((r.rec.final.unjudged_signals || []).slice().sort(), [S3, S5]);
  assert.deepStrictEqual(r.rec.final.signals, [S2], "the unjudged signals are not folded into the fired set");
});
test("complexity, S3 p=0.95 alone (others 0.5): need-subagent, S2/S5 delegated (S3 not decisive)", () => {
  const r = run("complexity", 0.5, { [S3]: 0.95 });
  assert.strictEqual(r.q.kv("RESULT"), "need-subagent", `query stdout: ${r.q.stdout}`);
  assert.strictEqual(J.keyset(r.q.kv("DELEGATED")), "s2_architecture,s5_breaking");
  const f = J.finalize(r.fx, mock, r.ticket);
  assert.strictEqual(f.status, 0);
  assert.strictEqual(J.decision(r.fx, r.ticket).short_circuited, false);
});
test("complexity, the 2026-10-15 re-aggregation record (S2 0.21 / S3 0.86 / S5 0.19): need-subagent", () => {
  const r = run("complexity", 0.5, { [S2]: 0.21, [S3]: 0.86, [S5]: 0.19 });
  assert.strictEqual(r.q.kv("RESULT"), "need-subagent", `query stdout: ${r.q.stdout}`);
  assert.strictEqual(J.keyset(r.q.kv("DELEGATED")), "s2_architecture,s5_breaking");
});
for (const stage of ["outline", "detail"]) {
  test(`${stage}, S3 p=0.95 alone: need-subagent; S5 p=0.95: final`, () => {
    const s3 = run(stage, 0.5, { [S3]: 0.95 });
    assert.strictEqual(s3.q.kv("RESULT"), "need-subagent", `S3 query stdout: ${s3.q.stdout}`);
    assert.strictEqual(J.keyset(s3.q.kv("DELEGATED")), "s2_architecture,s5_breaking");
    const s5 = run(stage, 0.5, { [S5]: 0.95 });
    assert.strictEqual(s5.q.kv("RESULT"), "final", `S5 query stdout: ${s5.q.stdout}`);
    assert.strictEqual(s5.rec.short_circuited, true);
  });
}
for (const stage of ["write-tests", "write-code"]) {
  test(`${stage}, S3 p=0.95 alone: final (decisive at this stage)`, () => {
    const r = run(stage, 0.5, { [S3]: 0.95 });
    assert.strictEqual(r.q.kv("RESULT"), "final", `query stdout: ${r.q.stdout}`);
    assert.strictEqual(r.rec.short_circuited, true);
    assert.ok(r.f.kv("SIGNALS_CSV").split(",").includes(S3), `SIGNALS_CSV ${r.f.kv("SIGNALS_CSV")}`);
  });
}
for (const p of [0.01, 0.1, 0.49]) {
  test(`all p=${p} (no-fire side, never adopted): need-subagent with all three keys delegated`, () => {
    const r = run("complexity", p);
    assert.strictEqual(r.q.kv("RESULT"), "need-subagent", `query stdout: ${r.q.stdout}`);
    assert.strictEqual(J.keyset(r.q.kv("DELEGATED")), ALL3);
  });
}
test("true side boundary: S2 p=0.7 adopted (short circuit); S2 p=0.69 held", () => {
  const at = run("complexity", 0.5, { [S2]: 0.7 });
  assert.strictEqual(at.q.kv("RESULT"), "final", `p=0.7 query stdout: ${at.q.stdout}`);
  const below = run("complexity", 0.5, { [S2]: 0.69 });
  assert.strictEqual(below.q.kv("RESULT"), "need-subagent", `p=0.69 query stdout: ${below.q.stdout}`);
  assert.strictEqual(J.keyset(below.q.kv("DELEGATED")), ALL3);
});
test("the decision record carries threshold {true:0.7,false:null} and short_circuit_answer true", () => {
  const r = run("complexity", 0.5, { [S2]: 0.99 });
  assert.ok(r.rec, "a decision record for the final (short-circuited) ticket");
  assert.deepStrictEqual(r.rec.threshold, { true: 0.7, false: null });
  assert.strictEqual(r.rec.short_circuit_answer, true);
});
caseEnd();

caseBegin("gate-null-false-direction", "hooks/lib/jev/two-stage/gate.js");
// decides always false isolates per-key adoption from the short circuit.
const NO_SC = { decides: () => false };
// [p, adopted value or undefined when held, why]
const NULL_ROWS = [
  [0.01, undefined, "false side null: conf 0.99 still held"],
  [0.49, undefined, "false side null: held"],
  [0.7, true, "true side at its bar 0.7: adopted"],
  [0.69, undefined, "true side 0.69 < 0.7: held"],
];
for (const [p, want, why] of NULL_ROWS) {
  test(`{true:0.7,false:null}, p=${p}: ${want === undefined ? "held" : "adopted " + want} (${why})`, () => {
    const g = applyGate({ k: { p } }, POLICY, NO_SC);
    assert.strictEqual(g.adopted.k, want);
    assert.deepStrictEqual(g.delegated, want === undefined ? ["k"] : []);
    assert.strictEqual(g.result, want === undefined ? "need-subagent" : "final");
  });
}
test("mixed: a non-decisive adopted true plus p=0.01 -> need-subagent, the p=0.01 key delegated", () => {
  const g = applyGate({ t: { p: 0.95 }, z: { p: 0.01 } }, POLICY, NO_SC);
  assert.deepStrictEqual(g.adopted, { t: true });
  assert.deepStrictEqual(g.delegated, ["z"]);
  assert.strictEqual(g.short_circuited, false);
  assert.strictEqual(g.result, "need-subagent");
});
caseEnd();

caseBegin("registry-null-threshold-schema", "hooks/lib/jev/registry.js");
const { validateRegistry, registryEntry } = require(REGISTRY_JS);
const CX = REGISTRY["complexity-judge"];
// withThr(t): a copy of the complexity entry whose threshold object is t.
const withThr = (t) => Object.assign({}, CX, { confidence_threshold_by_answer: t });
test("every shipped entry is valid", () => {
  for (const p of ["complexity-judge", "outline-skip", "detail-skip"]) {
    assert.deepStrictEqual(validateRegistry(REGISTRY[p]), [], p);
  }
});
test("registryEntry(complexity-judge) returns the entry", () => {
  assert.strictEqual(registryEntry("complexity-judge"), CX);
});
// [label, threshold object, accepted?]
const THR_ROWS = [
  ["{true:0.7,false:null}", { true: 0.7, false: null }, true],
  ["{true:null,false:0.7}", { true: null, false: 0.7 }, true],
  ["{true:null,false:null}", { true: null, false: null }, false],
  ["{true:0.7,false:0.4} (out of range)", { true: 0.7, false: 0.4 }, false],
  ["{true:0.7,false:\"x\"}", { true: 0.7, false: "x" }, false],
  ["{true:0.7,false:undefined}", { true: 0.7, false: undefined }, false],
  ["{true:0.7} (false key missing)", { true: 0.7 }, false],
  ["{true:0.7,false:null,maybe:0.8} (extra key)", { true: 0.7, false: null, maybe: 0.8 }, false],
  ["{true:0.7,false:NaN}", { true: 0.7, false: NaN }, false],
  ["{true:0.7,false:Infinity}", { true: 0.7, false: Infinity }, false],
];
for (const [label, t, ok] of THR_ROWS) {
  test(`validateRegistry threshold ${label}: ${ok ? "accepted" : "rejected"}`, () => {
    const errs = validateRegistry(withThr(t));
    if (ok) assert.deepStrictEqual(errs, []);
    else assert.ok(errs.some((e) => e.startsWith("confidence_threshold_by_answer")), `errors: ${JSON.stringify(errs)}`);
  });
}
caseEnd();
