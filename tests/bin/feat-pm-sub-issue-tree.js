"use strict";
// Tests: bin/lib/sub-issue-tree.js
// Tags: TL2, scope:issue-specific, pm-session, pm-field, forge, gh, issue-2942
// #2942: fetchSubIssueTree reads every descendant of an issue with its PM field value and state (the one-owner
// check of /pm-init and /pm-add); a cut-off level is read again up to maxCalls, and anything it cannot see whole
// fails closed. Paging and frontier cases use a stub batchedGraphql; one case runs the real one on the fake gh.
// TL3 gap (what this test does NOT catch):
// - a real GitHub sub-issue tree deeper than SUB_DEPTH, or a real page of more than 20 sub-issues.
const { test, after } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
after(() => { restore(); });

const SRC = path.join(P.ROOT, "bin", "lib", "sub-issue-tree.js");
const LINKS = path.join(P.ROOT, "bin", "lib", "forge-issue-links.js");
const R = (n, repo) => ({ number: n, repo: repo || "o/r" });
const key = (r) => `${r.repo}#${r.number}`;

// withStub(answer) -> {tree, calls}: sub-issue-tree loaded over a batchedGraphql whose answer(refs, call) is
// {[refKey]: node} or a whole-call {ok:false}; calls lists the refs each call asked.
function withStub(answer) {
  const real = require(LINKS);
  const calls = [];
  const saved = require.cache[LINKS];
  delete require.cache[SRC];
  const batchedGraphql = (refs) => {
    calls.push(refs.map(key));
    const a = answer(refs, calls.length);
    if (a && a.ok === false) return a;
    return { ok: true, results: Object.fromEntries(refs.map((r) => [key(r), a[key(r)] ? { ok: true, node: a[key(r)] } : { ok: false, reason: "issue_not_found" }])) };
  };
  require.cache[LINKS] = Object.assign({}, saved, { exports: Object.assign({}, real, { batchedGraphql }) });
  try { return { tree: require(SRC), calls }; } finally {
    require.cache[LINKS] = saved;
    delete require.cache[SRC];
  }
}
// node(n, pm, subs, o) -> a GraphQL issue node; subs: an array of nodes, or {cut: k} for a level cut off with k below.
function node(n, pm, subs, o = {}) {
  const sub = subs && subs.cut !== undefined ? { totalCount: subs.cut } : { nodes: subs || [], pageInfo: { hasNextPage: Boolean(o.more) }, totalCount: (subs || []).length };
  return { number: n, state: o.state || "OPEN", repository: { nameWithOwner: o.repo || "o/r" }, projectItems: { nodes: [{ id: `I${n}`, pm: pm ? { text: pm } : null, project: { id: "P", field: { id: "F" } } }] }, subIssues: sub };
}
const desc = (r, ref) => r.results[key(ref)].descendants.map((d) => `${d.repo}#${d.number}:${d.pm}:${d.state}`);

caseBegin("sub-issue-tree-descendants", "bin/lib/sub-issue-tree.js");
test("ST1 every descendant comes with its PM field value and state, across repos", () => {
  const { tree } = withStub(() => ({ "o/r#1": node(1, null, [node(2, "PM-a", [node(3, null, [], { state: "CLOSED", repo: "x/y" })])]) }));
  const r = tree.fetchSubIssueTree([R(1)]);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.deepStrictEqual(desc(r, R(1)), ["o/r#2:PM-a:OPEN", "x/y#3:null:CLOSED"]);
});
test("ST1 a leaf has no descendants; a repeated ref is asked once", () => {
  const { tree, calls } = withStub(() => ({ "o/r#5": node(5, "PM-b") }));
  const r = tree.fetchSubIssueTree([R(5), R(5)]);
  assert.deepStrictEqual(r.results["o/r#5"], { ok: true, descendants: [] });
  assert.deepStrictEqual(calls, [["o/r#5"]]);
});
test("ST1 the real batchedGraphql on the fake gh: one call, nested sub-issues with their PM field", () => {
  G.setMap({ "o/r#9101": {}, "o/r#9102": { parent: R(9101), pm: "PM-st" }, "o/r#9103": { parent: R(9102), state: "CLOSED" } });
  const before = G.calls();
  const r = P.load("bin/lib/sub-issue-tree.js").fetchSubIssueTree([R(9101)]);
  assert.strictEqual(G.calls() - before, 1);
  assert.deepStrictEqual(desc(r, R(9101)), ["o/r#9102:PM-st:OPEN", "o/r#9103:null:CLOSED"]);
});
caseEnd();

caseBegin("sub-issue-tree-frontier-and-fail-closed", "bin/lib/sub-issue-tree.js");
test("ST2 a level cut off below SUB_DEPTH is read again in the next call and joins its root's result", () => {
  const { tree, calls } = withStub((refs, call) => (call === 1 ? { "o/r#10": node(10, null, [node(11, null, { cut: 1 })]) } : { "o/r#11": node(11, null, [node(12, "PM-deep")]) }));
  const r = tree.fetchSubIssueTree([R(10)]);
  assert.deepStrictEqual(calls, [["o/r#10"], ["o/r#11"]]);
  assert.deepStrictEqual(desc(r, R(10)), ["o/r#11:null:OPEN", "o/r#12:PM-deep:OPEN"]);
});
test("ST2 a frontier left after maxCalls is sub-issue-depth-cap", () => {
  const { tree, calls } = withStub((refs) => Object.fromEntries(refs.map((x) => [key(x), node(x.number, null, [node(x.number + 1, null, { cut: 1 })])])));
  const r = tree.fetchSubIssueTree([R(20)], { maxCalls: 2 });
  assert.strictEqual(calls.length, 2);
  assert.deepStrictEqual(r.results["o/r#20"], { ok: false, reason: "sub-issue-depth-cap" });
});
test("ST2 a truncated page is sub-issue-overflow; one root's failure leaves another root whole", () => {
  const { tree } = withStub(() => ({ "o/r#30": node(30, null, [node(31)], { more: true }), "o/r#40": node(40, null, [node(41, "PM-ok")]) }));
  const r = tree.fetchSubIssueTree([R(30), R(40)]);
  assert.deepStrictEqual(r.results["o/r#30"], { ok: false, reason: "sub-issue-overflow" });
  assert.deepStrictEqual(desc(r, R(40)), ["o/r#41:PM-ok:OPEN"]);
});
test("ST2 a child without a number or a repo is parse_failed; a missing root carries the forge's reason", () => {
  const bad = node(50, null, [{ number: 51, repository: {} }]);
  const { tree } = withStub(() => ({ "o/r#50": bad }));
  const r = tree.fetchSubIssueTree([R(50), R(60)]);
  assert.deepStrictEqual(r.results["o/r#50"], { ok: false, reason: "parse_failed" });
  assert.deepStrictEqual(r.results["o/r#60"], { ok: false, reason: "issue_not_found" });
});
test("ST2 a whole-call failure is returned as is", () => {
  const { tree } = withStub(() => ({ ok: false, reason: "gh_exec_failed" }));
  assert.deepStrictEqual(tree.fetchSubIssueTree([R(70)]), { ok: false, reason: "gh_exec_failed" });
});
caseEnd();

caseBegin("sub-issue-tree-pm-field-ambiguous", "bin/lib/sub-issue-tree.js");
// two(n, a, b) -> a node on two Projects whose pm values are a and b.
const two = (n, a, b) => Object.assign(node(n, a), { projectItems: { nodes: [{ id: `I${n}a`, pm: a ? { text: a } : null }, { id: `I${n}b`, pm: b ? { text: b } : null }] } });
test("ST3 a descendant on two Projects naming different PMs fails its root with pm-field-ambiguous", () => {
  const { tree } = withStub(() => ({ "o/r#80": node(80, null, [two(81, "PM-a", "PM-b")]), "o/r#90": node(90, null, [node(91, "PM-ok")]) }));
  const r = tree.fetchSubIssueTree([R(80), R(90)]);
  assert.deepStrictEqual(r.results["o/r#80"], { ok: false, reason: "pm-field-ambiguous" });
  assert.deepStrictEqual(desc(r, R(90)), ["o/r#91:PM-ok:OPEN"]);
});
test("ST3 the same tag on both Projects (case aside) reads that tag", () => {
  const { tree } = withStub(() => ({ "o/r#85": node(85, null, [two(86, "PM-a", "pm-a")]) }));
  assert.deepStrictEqual(desc(tree.fetchSubIssueTree([R(85)]), R(85)), ["o/r#86:PM-a:OPEN"]);
});
caseEnd();
