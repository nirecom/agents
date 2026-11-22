"use strict";
// Batched `owner` cases of tests/bin/feature-2941-pm-state-cli.js (#2942 S21). No case markers.
// `--issue` may repeat: 2+ issues print {owners:[{issue, tag, session_id} | {issue, pm:null}]} in input order;
// exactly one keeps the #2991 gate shape ({tag, session_id} | {pm:null}). Any undecidable issue -> exit 1;
// a malformed --issue anywhere -> exit 2.
const assert = require("node:assert");
const { test } = require("node:test");
const { SID, TAG } = require("./world");

const brief = (r) => `code=${r.code} out=${r.out} err=${r.err}`;
const ok = (r) => assert.strictEqual(r.code, 0, brief(r));
const owners = (r) => {
  ok(r);
  assert.ok(r.json && Array.isArray(r.json.owners), `no owners array: ${brief(r)}`);
  return r.json.owners;
};
// names(entry, n) -> asserts the entry's issue label identifies issue n (the label form is not pinned).
const names = (e, n) => assert.ok(typeof e.issue === "string" && new RegExp(`#${n}$`).test(e.issue), `issue label ${JSON.stringify(e.issue)} is not #${n}`);
const owned = (e, n, tag, sid) => {
  names(e, n);
  assert.deepStrictEqual({ tag: e.tag, session_id: e.session_id }, { tag, session_id: sid }, JSON.stringify(e));
};
const unowned = (e, n) => {
  names(e, n);
  assert.strictEqual(e.pm, null, JSON.stringify(e));
  assert.ok(!("tag" in e) && !("session_id" in e), JSON.stringify(e));
};
const issues = (refs) => refs.flatMap((ref) => ["--issue", ref]);

function batch(F) {
  test("A1 two issues both owned via the PM field -> owners of 2 with tag and session_id, in input order", () => {
    const o = owners(F.run(["owner", ...issues(["o/r#300", "#103"])]));
    assert.strictEqual(o.length, 2, JSON.stringify(o));
    owned(o[0], 300, TAG.A, SID.A);
    owned(o[1], 103, TAG.F, SID.F);
  });
  test("A1 the reversed input order reverses the owners array", () => {
    const o = owners(F.run(["owner", ...issues(["#103", "#300"])]));
    assert.strictEqual(o.length, 2, JSON.stringify(o));
    owned(o[0], 103, TAG.F, SID.F);
    owned(o[1], 300, TAG.A, SID.A);
  });
  test("A2 one owned and one unowned -> the unowned entry is {issue, pm:null}", () => {
    const o = owners(F.run(["owner", ...issues(["#300", "#500"])]));
    assert.strictEqual(o.length, 2, JSON.stringify(o));
    owned(o[0], 300, TAG.A, SID.A);
    unowned(o[1], 500);
  });
  test("A2 an issue held by an archived PM only is {issue, pm:null} inside the batch too", () => {
    const o = owners(F.run(["owner", ...issues(["#400", "#103"])]));
    unowned(o[0], 400);
    owned(o[1], 103, TAG.F, SID.F);
  });
  test("A3 exactly one --issue keeps the gate shape: {tag, session_id}, no owners key", () => {
    const r = F.run(["owner", "--issue", "#300"]);
    ok(r);
    assert.deepStrictEqual(r.json, { tag: TAG.A, session_id: SID.A }, brief(r));
  });
  test("A3 exactly one unowned --issue keeps {pm:null}, no owners key", () => {
    const r = F.run(["owner", "--issue", "#500"]);
    ok(r);
    assert.deepStrictEqual(r.json, { pm: null }, brief(r));
  });
  for (const refs of [["#300", "#800"], ["#800", "#300"], ["#103", "#600"]]) {
    test(`A4 one undecidable issue in ${refs.join(" ")} -> exit 1 with the reason on stderr (fail-closed)`, () => {
      const r = F.run(["owner", ...issues(refs)]);
      assert.strictEqual(r.code, 1, brief(r));
      assert.ok(r.err.trim().length > 0, brief(r));
    });
  }
  for (const refs of [["#300", "abc"], ["abc", "#300"], ["#300", "#0"], ["#0", "#103"]]) {
    test(`A5 a malformed --issue in ${refs.join(" ")} -> exit 2 before any forge call`, () => {
      const r = F.run(["owner", ...issues(refs)]);
      assert.strictEqual(r.code, 2, brief(r));
      assert.strictEqual(r.calls.length, 0, JSON.stringify(r.calls));
    });
  }
  test("A6 two forge-chain issues in one call make no more forge reads than two single calls", () => {
    const one = F.run(["owner", "--issue", "#101"]);
    const two = F.run(["owner", "--issue", "#202"]);
    ok(one);
    ok(two);
    const r = F.run(["owner", ...issues(["#101", "#202"])]);
    const o = owners(r);
    owned(o[0], 101, TAG.A, SID.A);
    owned(o[1], 202, TAG.B, SID.B);
    const cap = one.calls.length + two.calls.length;
    assert.ok(r.calls.length <= cap, `batched forge reads ${r.calls.length} > ${cap} (single: ${one.calls.length} + ${two.calls.length})`);
  });
}

module.exports = { batch };
