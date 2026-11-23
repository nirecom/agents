"use strict";
// Tests: bin/lib/pm-field/read.js, bin/lib/sub-issue-tree.js
// Tags: TL2, scope:issue-specific, pm-session, pm-field, forge, gh, issue-3135
// #3135: a card on a Project without the `pm` field reads as pm=null with a "field absent" mark instead of
// failing the whole read (gh_exec_failed). Assumed contract: read.js exports itemsOf(pageSize) (the one
// projectItems shape; ITEMS === itemsOf(20)), pmReadOf(node) adds fieldAbsent:true, readPmFields adds
// fieldAbsent: {"<repo as given>#N": true}, readPmChains marks each chain entry, readCards answers no-card.
// TL3 gap (what this test does NOT catch):
// - the real GitHub error text and path of field(name:"pm") on a board without it; the fake gh mirrors its shape.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test, after } = require("node:test");
const P = require("../lib/pm-state-fixture");
const { ghEnv } = require("./feature-2941-pm-state-cli/gh-env");

const restore = isolate();
const G = ghEnv("pm-absent-read-");
after(() => { G.restore(); restore(); });

const R = () => P.load("bin/lib/pm-field/read.js");
const T = () => P.load("bin/lib/sub-issue-tree.js");
const ref = (n, repo) => ({ number: n, repo: repo || "o/r" });
const at = (n) => `o/r#${n}`;
const parent = (n) => ({ number: n, repo: "o/r" });

G.setMap({
  [at(9001)]: { noPmFieldBoard: true }, [at(9002)]: { pm: "PM-a" }, [at(9003)]: { noCard: true },
  [at(9004)]: { noPmField: true }, [at(9005)]: {},
  [at(9010)]: { noPmFieldBoard: true }, [at(9011)]: { noPmFieldBoard: true, parent: parent(9010) },
  [at(9020)]: {}, [at(9021)]: { noPmFieldBoard: true, parent: parent(9020) },
  [at(9030)]: { innerError: "NOT_FOUND" }, [at(9031)]: { noPmFieldBoard: "FORBIDDEN" }, [at(9032)]: { missing: "NOT_FOUND" },
});
const brief = (r) => JSON.stringify(r).slice(0, 600);

caseBegin("items-shape-single-definition", "bin/lib/pm-field/read.js");
test("I1 itemsOf(pageSize) is the one projectItems shape; ITEMS is its 20-card page", () => {
  const f = R().itemsOf;
  assert.strictEqual(typeof f, "function", "read.js exports no itemsOf");
  assert.match(f(20), /projectItems\(first:\s*20\)/);
  assert.match(f(10), /projectItems\(first:\s*10\)/);
  assert.strictEqual(f(20).replace(/first:\s*20/, "first:N"), f(10).replace(/first:\s*10/, "first:N"));
  assert.strictEqual(R().ITEMS, f(20));
  assert.match(f(20), /field\(name:\s*"pm"\)/);
});
test("I2 sub-issue-tree.js keeps no projectItems shape of its own", () => {
  const src = fs.readFileSync(path.join(P.ROOT, "bin", "lib", "sub-issue-tree.js"), "utf8");
  assert.doesNotMatch(src, /projectItems\s*\(/, "sub-issue-tree.js still spells out the projectItems shape");
});
test("I3 the page sizes stay per consumer: readPmFields asks 20 cards, fetchSubIssueTree 10", () => {
  const b = G.queries().length;
  R().readPmFields([ref(9005)]);
  const q1 = G.queries().slice(b).join("\n");
  assert.match(q1, /projectItems\(first:\s*20\)/);
  const b2 = G.queries().length;
  T().fetchSubIssueTree([ref(9005)]);
  const q2 = G.queries().slice(b2).join("\n");
  assert.match(q2, /projectItems\(first:\s*10\)/);
  assert.doesNotMatch(q2, /projectItems\(first:\s*20\)/);
});
caseEnd();

caseBegin("pm-field-absent-mark", "bin/lib/pm-field/read.js");
test("A1 GitHub's answer for a board without pm (field null + NOT_FOUND) reads pm=null with the absent mark", () => {
  const r = R().readPmFields([ref(9001), ref(9002)]);
  assert.strictEqual(r.ok, true, brief(r));
  assert.strictEqual(r.values[at(9001)], null);
  assert.strictEqual(r.values[at(9002)], "PM-a", "a sibling with a value is read as before");
  assert.ok(r.fieldAbsent && r.fieldAbsent[at(9001)] === true, brief(r));
  assert.ok(!r.fieldAbsent[at(9002)], brief(r));
});
test("A2 a card whose project.field is null in data (no error) carries the mark too", () => {
  const r = R().readPmFields([ref(9004)]);
  assert.strictEqual(r.ok, true, brief(r));
  assert.strictEqual(r.values[at(9004)], null);
  assert.ok(r.fieldAbsent && r.fieldAbsent[at(9004)] === true, brief(r));
});
test("A3 an empty field and an issue with no card read null without the mark", () => {
  const r = R().readPmFields([ref(9005), ref(9003)]);
  assert.strictEqual(r.ok, true, brief(r));
  assert.strictEqual(r.values[at(9005)], null);
  assert.strictEqual(r.values[at(9003)], null);
  const marks = r.fieldAbsent || {};
  assert.ok(!marks[at(9005)] && !marks[at(9003)], brief(r));
});
test("A4 pmReadOf: every card on a field-less board -> mark; one board with the field -> no mark", () => {
  const card = (field, text) => ({ id: "I", pm: text ? { text } : null, project: { id: "P", field } });
  const node = (...cards) => ({ number: 1, projectItems: { nodes: cards, pageInfo: { hasNextPage: false } } });
  assert.deepStrictEqual(R().pmReadOf(node(card(null))), { ok: true, pm: null, fieldAbsent: true });
  const mixed = R().pmReadOf(node(card(null), card({ id: "F" })));
  assert.strictEqual(mixed.ok, true);
  assert.strictEqual(mixed.pm, null);
  assert.ok(!mixed.fieldAbsent, brief(mixed));
  const set = R().pmReadOf(node(card({ id: "F" }, "PM-z")));
  assert.deepStrictEqual([set.ok, set.pm, Boolean(set.fieldAbsent)], [true, "PM-z", false], brief(set));
});
test("A5 readPmChains marks the issue and its ancestor on a field-less board", () => {
  const r = R().readPmChains([ref(9011)]);
  assert.strictEqual(r.ok, true, brief(r));
  const c = r.results[at(9011)];
  assert.ok(c && c.ok, brief(r));
  assert.deepStrictEqual(c.chain.map((e) => [e.number, e.pm, e.fieldAbsent === true]), [[9011, null, true], [9010, null, true]]);
});
caseEnd();

caseBegin("pm-field-absent-card", "bin/lib/pm-field/read.js");
test("C1 readCards: a card only on a field-less board is no-card, not gh_exec_failed", () => {
  const r = R().readCards([ref(9001)]);
  assert.strictEqual(r.ok, true, brief(r));
  assert.deepStrictEqual(r.results[at(9001)], { ok: false, reason: "no-card" });
});
caseEnd();

caseBegin("pm-field-absent-sub-issue-tree", "bin/lib/sub-issue-tree.js");
test("S1 a descendant on a field-less board reads pm=null and leaves its root readable", () => {
  const r = T().fetchSubIssueTree([ref(9020)]);
  assert.strictEqual(r.ok, true, brief(r));
  const root = r.results[at(9020)];
  assert.ok(root && root.ok, brief(r));
  const d = root.descendants.find((x) => x.number === 9021);
  assert.ok(d, brief(r));
  assert.strictEqual(d.pm, null);
});
caseEnd();

caseBegin("pm-field-absent-non-regression", "bin/lib/pm-field/read.js");
test("N1 a NOT_FOUND at the card's project (not its field) still fails the read", () => {
  assert.deepStrictEqual(R().readPmFields([ref(9030)]), { ok: false, reason: "gh_exec_failed" });
});
test("N2 another error type at project.field still fails the read", () => {
  assert.deepStrictEqual(R().readPmFields([ref(9031)]), { ok: false, reason: "gh_exec_failed" });
  const c = R().readCards([ref(9031)]);
  assert.strictEqual(c.ok, true, brief(c));
  assert.deepStrictEqual(c.results[at(9031)], { ok: false, reason: "gh_exec_failed" });
});
test("N3 a missing issue (NOT_FOUND at its alias) stays issue_not_found; its field-less neighbour is no-card", () => {
  const c = R().readCards([ref(9032), ref(9001)]);
  assert.strictEqual(c.ok, true, brief(c));
  assert.deepStrictEqual(c.results[at(9032)], { ok: false, reason: "issue_not_found" });
  assert.deepStrictEqual(c.results[at(9001)], { ok: false, reason: "no-card" });
});
test("N4 readPmChains: a NOT_FOUND at project and a FORBIDDEN at project.field stay gh_exec_failed", () => {
  for (const num of [9030, 9031]) {
    const r = R().readPmChains([ref(num)]);
    const got = r.ok === false ? r : r.results && r.results[at(num)];
    assert.deepStrictEqual(got, { ok: false, reason: "gh_exec_failed" }, `#${num}: ${brief(r)}`);
  }
});
caseEnd();
