"use strict";
// tests/bin/feature-2941-pm-state-ancestry.js
// Tests: bin/lib/pm-state/ancestry.js, bin/lib/pm-state/overlap.js
// Tags: TL1, scope:issue-specific, pm-session, forge, gh
// #2941 the range rule (holdersOf: direct + every held meta ancestor), its failure classes and
// retryability, prefetch batching / memo / deadline, and findOverlap's directions and priority.
// The real fetchAncestorChains runs against a fake gh (tests/bin/feature-2941-pm-state-cli/fake-gh.js).
// TL3 gap: real GitHub sub-issue chains and label pages are not queried; the fake answers their shape.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const P = require("../lib/pm-state-fixture");
const { ghEnv } = require("./feature-2941-pm-state-cli/gh-env");

const restore = isolate();
const G = ghEnv("pm-ancestry-");
after(() => { G.restore(); restore(); });

const R = (n) => ({ number: n, repo: "o/r" });
const H = (tag, nums) => ({ tag, session_id: P.uuid(0x2941a000 + nums[0]), issues: nums.map(R) });
const meta = (parent) => ({ parent: parent ? R(parent) : null, labels: ["bug", "meta"] });
const plain = (parent) => ({ parent: parent ? R(parent) : null, labels: ["bug"] });
// World: 100 meta > 110 meta > 111 > 112; 200 plain > 201; 300 plain(held) > 302; 400 label page
// overflow > 401; 500 > 501 > … > 511 (11 ancestors); 600 meta > … > 608 (depth 8); 700 missing;
// 800 <-> 801 cycle. Overlap: 1000 meta A > 1010 meta B > 1011 C, 1012 D; 1100 plain S > 1101.
const MAP = {
  "o/r#100": meta(), "o/r#110": meta(100), "o/r#111": plain(110), "o/r#112": plain(111),
  "o/r#200": plain(), "o/r#201": plain(200), "o/r#300": plain(), "o/r#302": plain(300),
  "o/r#400": { parent: null, labels: ["x"], more: true }, "o/r#401": plain(400),
  "o/r#600": meta(), "o/r#700": { missing: true }, "o/r#800": plain(801), "o/r#801": plain(800),
  "o/r#1000": meta(), "o/r#1010": meta(1000), "o/r#1011": plain(1010), "o/r#1012": plain(1010),
  "o/r#1100": plain(), "o/r#1101": plain(1100),
};
for (let i = 501; i <= 511; i++) MAP[`o/r#${i}`] = plain(i - 1);
MAP["o/r#500"] = plain();
for (let i = 601; i <= 608; i++) MAP[`o/r#${i}`] = plain(i - 1);
G.setMap(MAP);

const A = () => P.load("bin/lib/pm-state/ancestry.js");
const O = () => P.load("bin/lib/pm-state/overlap.js");
const L = () => P.load("bin/lib/forge-issue-links.js");

// mk(opts) -> a fresh ancestry over the real fetchAncestorChains; asserts the new contract's shape.
function mk(o = {}) {
  const links = L();
  assert.strictEqual(typeof links.fetchAncestorChains, "function", "forge-issue-links.fetchAncestorChains is missing");
  const a = A().createAncestry(Object.assign({ fetchAncestorChains: links.fetchAncestorChains, now: () => Date.now() }, o));
  assert.strictEqual(typeof a.prefetch, "function", "createAncestry(...).prefetch is missing");
  assert.strictEqual(typeof a.holdersOf, "function", "createAncestry(...).holdersOf is missing");
  return a;
}
function holders(ref, hs, o) {
  const a = mk(o);
  a.prefetch([ref].concat(...hs.map((h) => h.issues)));
  return a.holdersOf(ref, hs);
}
const viaNums = (r) => (r.viaMeta || []).map((v) => v.ancestor.number).sort((x, y) => x - y);
const fails = (r, reason, retryable) => {
  assert.strictEqual(r.ok, false, JSON.stringify(r));
  assert.strictEqual(r.reason, reason, JSON.stringify(r));
  assert.strictEqual(r.retryable, retryable, JSON.stringify(r));
};

caseBegin("ancestry-holders-of-range-rule", "bin/lib/pm-state/ancestry.js");
test("children and grandchildren of a held meta are in its range", () => {
  const h = H("PM-am", [110]);
  for (const n of [111, 112]) {
    const r = holders(R(n), [h]);
    assert.strictEqual(r.ok, true, JSON.stringify(r));
    assert.deepStrictEqual(viaNums(r), [110], `#${n}`);
    assert.strictEqual(r.viaMeta[0].holder.tag, "PM-am");
  }
});
test("a child of a held plain issue is out of range unless a held meta is above", () => {
  const r = holders(R(201), [H("PM-ap", [200])]);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.deepStrictEqual(r.direct, []);
  assert.deepStrictEqual(r.viaMeta, []);
});
test("a held ancestor without the meta label is no hit", () => {
  const r = holders(R(302), [H("PM-an", [300])]);
  assert.deepStrictEqual([r.ok, r.viaMeta], [true, []], JSON.stringify(r));
});
test("viaMeta returns every held meta up to the root (no nearest-wins)", () => {
  const r = holders(R(111), [H("PM-a1", [100]), H("PM-a2", [110])]);
  assert.deepStrictEqual(viaNums(r), [100, 110], JSON.stringify(r));
});
test("direct lists the holder of the ref itself", () => {
  const r = holders(R(111), [H("PM-ad", [111])]);
  assert.deepStrictEqual(r.direct.map((h) => h.tag), ["PM-ad"], JSON.stringify(r));
});
test("a chain of depth 8 resolves to its meta root", () => {
  assert.deepStrictEqual(viaNums(holders(R(608), [H("PM-a8", [600])])), [600]);
});
caseEnd();

caseBegin("ancestry-failure-classes", "bin/lib/pm-state/ancestry.js");
test("a held ancestor whose labels overflow the first page is label-overflow, not retryable", () => {
  fails(holders(R(401), [H("PM-ao", [400])]), "label-overflow", false);
});
test("label overflow on an ancestor nobody holds does not matter", () => {
  const r = holders(R(401), [H("PM-ax", [100])]);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
});
test("a parent at the cap level is depth-cap; a missing alias is issue_not_found; a loop is cycle", () => {
  const h = H("PM-af", [100]);
  fails(holders(R(511), [h]), "depth-cap", false);
  fails(holders(R(700), [h]), "issue_not_found", false);
  fails(holders(R(800), [h]), "cycle", false);
});
test("a ref without a repo is repo-unknown, not retryable", () => {
  const a = mk();
  a.prefetch([R(100)]);
  fails(a.holdersOf({ number: 100 }, [H("PM-ar", [100])]), "repo-unknown", false);
});
// #2942: a parse failure does not heal on retry (the same forge answer parses the same way).
// #3152: a deadline already passed is budget-exhausted (gh never ran), still retryable.
test("gh_exec_failed and budget-exhausted are retryable; parse_failed is not", () => {
  const h = H("PM-ag", [100]);
  try {
    G.mode("fail");
    fails(holders(R(111), [h]), "gh_exec_failed", true);
    G.mode("garbage");
    fails(holders(R(111), [h]), "parse_failed", false);
  } finally { G.mode(null); }
  fails(holders(R(111), [h], { deadlineAt: Date.now() - 1 }), "budget-exhausted", true);
});
test("a timeout stored before #3152 still reads as retryable", () => {
  const a = A().createAncestry({ fetchAncestorChains: () => ({ ok: false, reason: "timeout" }), now: () => Date.now() });
  a.prefetch([R(111)]);
  fails(a.holdersOf(R(111), [H("PM-at", [110])]), "timeout", true);
});
test("MAX_ANCESTOR_DEPTH stays 10", () => {
  assert.strictEqual(A().MAX_ANCESTOR_DEPTH, 10);
});
caseEnd();

caseBegin("ancestry-prefetch-batch-memo-deadline", "bin/lib/pm-state/ancestry.js");
test("up to 50 refs are one query; a second prefetch of the same refs asks nothing", () => {
  const a = mk();
  const refs = Array.from({ length: 50 }, (_, i) => R(2000 + i));
  const before = G.calls();
  a.prefetch(refs);
  assert.strictEqual(G.calls() - before, 1);
  a.prefetch(refs.slice(0, 10));
  assert.strictEqual(G.calls() - before, 1, "memoised refs were asked again");
});
test("a deadline already passed asks nothing and every ref reads budget-exhausted", () => {
  const a = mk({ deadlineAt: Date.now() - 1 });
  const before = G.calls();
  a.prefetch([R(111), R(201)]);
  assert.strictEqual(G.calls() - before, 0);
  fails(a.holdersOf(R(111), [H("PM-dl", [110])]), "budget-exhausted", true);
});
caseEnd();

// overlap(adds, others) -> findOverlap over a fresh ancestry; counts the gh calls it made.
function overlap(adds, others) {
  const f = O().findOverlap;
  assert.strictEqual(typeof f, "function", "overlap.findOverlap is missing");
  const before = G.calls();
  const r = f(adds.map(R), "PM-me", others, mk());
  return { r, calls: G.calls() - before };
}
const isOverlap = (r, tag, viaN) => {
  assert.strictEqual(r.ok, false, JSON.stringify(r));
  assert.strictEqual(r.kind, "overlap", JSON.stringify(r));
  assert.strictEqual(r.tag, tag, JSON.stringify(r));
  assert.ok(JSON.stringify(r.via).includes(String(viaN)), JSON.stringify(r));
};

caseBegin("overlap-directions-and-priority", "bin/lib/pm-state/overlap.js");
test("under A's PM, adding meta B, C or D overlaps upward via A", () => {
  const pmA = H("PM-oA", [1000]);
  for (const n of [1010, 1011, 1012]) isOverlap(overlap([n], [pmA]).r, "PM-oA", 1000);
});
test("under B's PM, adding meta A overlaps downward, a direction other than upward", () => {
  const down = overlap([1000], [H("PM-oB", [1010])]).r;
  isOverlap(down, "PM-oB", 1000);
  const up = overlap([1011], [H("PM-oA", [1000])]).r;
  assert.notStrictEqual(down.direction, up.direction, JSON.stringify([down, up]));
});
test("a child of another PM's plain issue S is free; S itself overlaps directly", () => {
  const pmS = H("PM-oS", [1100]);
  assert.deepStrictEqual(overlap([1101], [pmS]).r, { ok: true });
  assert.strictEqual(overlap([1100], [pmS]).r.kind, "overlap");
});
test("adds and the others' issues go to the forge in one query", () => {
  assert.strictEqual(overlap([1011, 1101, 111], [H("PM-o1", [1000]), H("PM-o2", [1100])]).calls, 1);
});
test("priority: overlap > unresolvable > unverified", () => {
  const pmA = H("PM-oA", [1000]);
  const pmO = H("PM-oO", [400]);
  assert.strictEqual(overlap([401, 1011], [pmA, pmO]).r.kind, "overlap");
  const u = overlap([401], [pmO]).r;
  assert.deepStrictEqual([u.kind, u.reason, u.ref && u.ref.number], ["unresolvable", "label-overflow", 401], JSON.stringify(u));
  try {
    G.mode("fail");
    const v = overlap([1011], [pmA]).r;
    assert.deepStrictEqual([v.kind, v.reason], ["unverified", "gh_exec_failed"], JSON.stringify(v));
  } finally { G.mode(null); }
});
caseEnd();

// #3152: the unverified refusal's next action comes from forge-failure.js nextActionOf (one wording source).
caseBegin("overlap-unverified-next-action", "bin/lib/pm-state/overlap.js");
test("an overlap check whose deadline is spent words its refusal with nextActionOf(budget-exhausted)", () => {
  const F = P.load("bin/lib/forge-failure.js");
  assert.strictEqual(typeof F.nextActionOf, "function", "bin/lib/forge-failure.js does not export nextActionOf (#3152)");
  const r = O().findOverlap([R(1011)], "PM-me", [H("PM-oN", [1000])], mk({ deadlineAt: Date.now() - 1 }));
  assert.deepStrictEqual([r.kind, r.reason], ["unverified", "budget-exhausted"], JSON.stringify(r));
  const text = O().refusalText(r);
  assert.ok(text.includes(F.nextActionOf("budget-exhausted")), `refusal lacks nextActionOf(budget-exhausted): ${text}`);
});
caseEnd();
