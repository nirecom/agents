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
// {[refKey]: node} or a whole-call {ok:false}; calls lists the refs each call asked. answer also gets the spec
// ({fields}) the call selected, so a fake can honor the query.
function withStub(answer) {
  const real = require(LINKS);
  const calls = [];
  const saved = require.cache[LINKS];
  delete require.cache[SRC];
  const batchedGraphql = (refs, spec) => {
    calls.push(refs.map(key));
    const a = answer(refs, calls.length, spec);
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

// #2942: a descendant whose projectItems page has more cards than fetched cannot be read whole -> its root
// fails with pm-field-truncated; the query asks every projectItems for pageInfo{hasNextPage} beside nodes.
function blockEnd(s, open) {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === "{") depth++;
    if (s[i] === "}" && --depth === 0) return i;
  }
  return s.length;
}
// itemsBodies(q) -> each projectItems(...){ } body of q with its nodes{...} block cut out.
function itemsBodies(q) {
  const out = [];
  for (const m of q.matchAll(/projectItems\([^)]*\)\{/g)) {
    const open = m.index + m[0].length - 1;
    const body = q.slice(open + 1, blockEnd(q, open));
    const n = body.indexOf("nodes{");
    out.push(n < 0 ? body : body.slice(0, n) + body.slice(blockEnd(body, n + 5) + 1));
  }
  return out;
}
const more = (nd) => Object.assign(nd, { projectItems: Object.assign(nd.projectItems, { pageInfo: { hasNextPage: true } }) });
caseBegin("sub-issue-tree-pm-field-truncated", "bin/lib/sub-issue-tree.js");
test("ST4 the query sent to gh asks every projectItems for pageInfo{hasNextPage}", () => {
  G.setMap({ "o/r#9201": {} });
  const before = G.calls();
  P.load("bin/lib/sub-issue-tree.js").fetchSubIssueTree([R(9201)]);
  const q = G.queries().slice(before).find((x) => x.includes("projectItems(")) || "";
  const bodies = itemsBodies(q);
  assert.ok(bodies.length > 0, `no projectItems in the query: ${q}`);
  for (const b of bodies) assert.match(b, /pageInfo\s*\{\s*hasNextPage\s*\}/, q);
});
test("ST4 a descendant with a truncated card page fails its root with pm-field-truncated; another root stays whole", () => {
  const { tree } = withStub(() => ({ "o/r#95": node(95, null, [node(96, null, [more(node(97, "PM-a"))])]), "o/r#98": node(98, null, [node(99, "PM-ok")]) }));
  const r = tree.fetchSubIssueTree([R(95), R(98)]);
  assert.deepStrictEqual(r.results["o/r#95"], { ok: false, reason: "pm-field-truncated" });
  assert.deepStrictEqual(desc(r, R(98)), ["o/r#99:PM-ok:OPEN"]);
});
test("ST4 the real batchedGraphql on the fake gh: a truncated descendant fails the root closed", () => {
  G.setMap({ "o/r#9211": {}, "o/r#9212": { parent: R(9211), pm: "PM-st", itemsMore: true } });
  const r = P.load("bin/lib/sub-issue-tree.js").fetchSubIssueTree([R(9211)]);
  assert.deepStrictEqual(r.results["o/r#9211"], { ok: false, reason: "pm-field-truncated" }, JSON.stringify(r));
});
caseEnd();

// #2942: every level down to SUB_DEPTH (3 in the source) must select projectItems, or a deep descendant's PM
// goes unread. The fake gh answers projectItems whatever is asked, so ST5 builds its answer from the query.
const SUB_DEPTH = 3;
// levelsOf(q) -> per nesting level (split on subIssues( ), whether that level selects projectItems.
const levelsOf = (q) => q.split("subIssues(").map((seg) => seg.includes("projectItems("));
// dropDeepestItems(q) -> q with its last projectItems(...){...} selection deleted.
function dropDeepestItems(q) {
  const at = q.lastIndexOf("projectItems(");
  return q.slice(0, at) + q.slice(blockEnd(q, q.indexOf("{", at)) + 1);
}
// chainFor(q, pms, more) -> root 500 with a single-child chain one issue per level; level i carries projectItems
// (pm pms[i], hasNextPage more[i]) only when q selects it there.
function chainFor(q, pms, more = []) {
  const levels = levelsOf(q);
  let below = { totalCount: 0 };
  for (let i = levels.length - 1; i >= 0; i--) {
    const nd = { number: 500 + i, state: "OPEN", repository: { nameWithOwner: "o/r" }, subIssues: below };
    if (levels[i]) nd.projectItems = { nodes: [{ id: `I${i}`, pm: pms[i] ? { text: pms[i] } : null }], pageInfo: { hasNextPage: Boolean(more[i]) } };
    below = { nodes: [nd], pageInfo: { hasNextPage: false }, totalCount: 1 };
  }
  return below.nodes[0];
}
// runChain(pms, more, mutate) -> fetchSubIssueTree's result for root 500 over a stub answering chainFor(query).
function runChain(pms, more, mutate = (q) => q) {
  const { tree } = withStub((refs, call, spec) => ({ "o/r#500": chainFor(mutate(spec.fields), pms, more) }));
  return tree.fetchSubIssueTree([R(500)]).results["o/r#500"];
}
caseBegin("sub-issue-tree-items-every-level", "bin/lib/sub-issue-tree.js");
test("ST5 the query selects projectItems with pageInfo once per level, root to SUB_DEPTH, each deeper", () => {
  G.setMap({ "o/r#9301": {} });
  const before = G.calls();
  P.load("bin/lib/sub-issue-tree.js").fetchSubIssueTree([R(9301)]);
  const q = G.queries().slice(before).find((x) => x.includes("projectItems(")) || "";
  assert.strictEqual((q.match(/projectItems\(/g) || []).length, SUB_DEPTH + 1, q);
  const segs = q.split("subIssues(");
  assert.strictEqual(segs.length, SUB_DEPTH + 1, q);
  for (const s of segs) {
    const bodies = itemsBodies(s);
    assert.strictEqual(bodies.length, 1, s);
    assert.match(bodies[0], /pageInfo\s*\{\s*hasNextPage\s*\}/, s);
  }
  const depthAt = (i) => [...q.slice(0, i)].reduce((d, c) => d + (c === "{") - (c === "}"), 0);
  const depths = [...q.matchAll(/projectItems\(/g)].map((m) => depthAt(m.index));
  for (let i = 1; i < depths.length; i++) assert.ok(depths[i] > depths[i - 1], `depths ${depths}`);
  assert.strictEqual((q.match(/subIssues\{totalCount\}/g) || []).length, 1, q);
  assert.match(segs[segs.length - 1], /subIssues\{totalCount\}/);
});
test("ST5 an answer built from the query: depth-2 and depth-3 descendants report their PM and truncation", () => {
  const ok = runChain([null, null, "PM-two", "PM-three"]);
  assert.deepStrictEqual(ok.descendants.map((d) => `${d.number}:${d.pm}`), ["501:null", "502:PM-two", "503:PM-three"]);
  assert.deepStrictEqual(runChain([], [false, false, true]), { ok: false, reason: "pm-field-truncated" });
  assert.deepStrictEqual(runChain([], [false, false, false, true]), { ok: false, reason: "pm-field-truncated" });
});
test("ST5 sensitivity: a query without the deepest projectItems loses the depth-3 PM and its truncation", () => {
  const lost = runChain([null, null, "PM-two", "PM-three"], [], dropDeepestItems);
  assert.deepStrictEqual(lost.descendants.map((d) => `${d.number}:${d.pm}`), ["501:null", "502:PM-two", "503:null"]);
  assert.strictEqual(runChain([], [false, false, false, true], dropDeepestItems).ok, true);
});
caseEnd();
