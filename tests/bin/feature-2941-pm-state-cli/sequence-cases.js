"use strict";
// set-sequence cases of tests/bin/feature-2941-pm-state-cli.js (#2941). No case markers.
// Payload of --file: {tables: [{title, meta?, waves: [{issues: [{number, reason, blocked_by, conflicts}]}]}]}.
// The caller is CLAUDE_CODE_SESSION_ID (fixture run's `caller`); set-sequence writes only the caller's table.
const assert = require("node:assert");
const { test } = require("node:test");
const { table, P } = require("./fixture");
const { SID, CAP_CHAINS } = require("./world");

const brief = (r) => `code=${r.code} out=${r.out} err=${r.err}`;
const seqOf = (sid) => P.readPm(sid).sequence;
const tablesOf = (sid) => (seqOf(sid) || {}).tables;
const failed = (r) => assert.ok(r.code !== 0 && r.code !== null && r.code !== 127, brief(r));
const text = (r) => `${r.out}\n${r.err}`;

// rejected(F, label, sid, payload, check, opts) — the write is refused and pm stays as it was.
function rejecter(F, set) {
  return (label, sid, payload, check, o) => test(label, () => {
    const before = JSON.stringify(P.readPm(sid));
    const r = set(sid, payload, o);
    failed(r);
    if (check) check(r, text(r));
    assert.strictEqual(JSON.stringify(P.readPm(sid)), before, "pm changed on a refused write");
  });
}
const setter = (F) => (sid, payload, o = {}) => F.run(["set-sequence", "--session", sid, "--file", F.seqFile(payload)], Object.assign({ caller: sid }, o));

function sequence(F) {
  const set = setter(F);
  const rejected = rejecter(F, set);
  test("Q1 a table of directly assigned issues is written", () => {
    const r = set(SID.A, table([100, 300]));
    assert.strictEqual(r.code, 0, brief(r));
    assert.deepStrictEqual(tablesOf(SID.A), table([100, 300]).tables);
    assert.ok(typeof seqOf(SID.A).updated_at === "string", JSON.stringify(seqOf(SID.A)));
  });
  test("Q2 a child and a grandchild of an assigned meta are in range", () => {
    const r = set(SID.A, table([100, 101, 102]));
    assert.strictEqual(r.code, 0, brief(r));
    assert.deepStrictEqual(tablesOf(SID.A), table([100, 101, 102]).tables);
  });
  rejected("Q3 an issue outside the range is refused and named", SID.A, table([100, 500]), (r, t) => assert.match(t, /500/, brief(r)));
  test("Q4 other PMs are not looked at: #202 under meta #100 is in A's range though B holds meta #200", () => {
    assert.strictEqual(set(SID.A, table([202])).code, 0);
  });
  for (const [label, n, reason] of [["a cycle", 600, "cycle"], ["a chain deeper than the cap", 700, "depth-cap"]]) {
    rejected(`Q5 ${label} is unresolvable: refused naming the issue and the reason`, SID.A, table([100, n]), (r, t) => {
      assert.ok(t.includes(String(n)) && t.includes(reason) && t.includes("unresolvable"), brief(r));
    });
  }
  rejected("Q5 a forge failure is unverified: refused naming the issue", SID.A, table([100, 800]), (r, t) => assert.ok(t.includes("800") && t.includes("unverified"), brief(r)));
  rejected("Q5 out-of-range wins over unresolvable and names the out-of-range issue", SID.A, table([500, 600]), (r, t) => assert.ok(t.includes("out-of-range") && t.includes("500"), brief(r)));
  rejected("Q5 a label-overflow issue is refused with the reason, the ref and the reduce-labels exit", SID.A, table([301]), (r, t) => {
    assert.ok(t.includes("label-overflow") && t.includes("301") && t.includes("to 100 or fewer and retry"), brief(r));
  });
  test("Q6 a table is checked with one forge query", () => {
    const r = set(SID.A, table([111, 112]));
    assert.strictEqual(r.code, 0, brief(r));
    assert.strictEqual(r.checkCalls.length, 1, JSON.stringify(r.calls));
  });
  rejected("Q7 an old generation cannot write", SID.Aold, table([100]));
  rejected("Q7 an archived PM cannot write", SID.C, table([400]));
  rejected("Q8 a malformed file is refused", SID.A, "not json {");
  rejected("Q8 tables that are not an array are refused", SID.A, { tables: "x" });
  test("Q9 a session without a PM is refused", () => {
    failed(set(SID.D, table([100])));
    assert.strictEqual(P.readPm(SID.D), undefined);
  });
  required(F, rejected, set);
  caller(F, rejected);
  race(F);
}

// race — the PM changes while the forge query runs (fake gh's PM_FAKE_GH_SIDE, a one-shot pm patch).
function race(F) {
  const fs = require("node:fs");
  const path = require("node:path");
  const sideRun = (sid, payload, patch) => {
    const side = path.join(path.dirname(F.seqFile("{}")), `side-${sid}.json`);
    fs.writeFileSync(side, JSON.stringify({ file: P.statePath(sid), patch }));
    const r = F.run(["set-sequence", "--file", F.seqFile(payload)], { caller: sid, env: { PM_FAKE_GH_SIDE: side } });
    return { r, fired: !fs.existsSync(side) };
  };
  // retire(sid) — archive a race PM so its issues (also held by SID.A) leave the later cases' world.
  const retire = (sid) => { const st = P.raw(sid); st.pm.archived_at = "2026-11-09T00:00:00.000Z"; P.writeRaw(sid, st); };
  test("Q17 the PM archived during the forge query: refused, the earlier table is kept", () => {
    const sid = P.uuid(0x29416301);
    const seq = { updated_at: "2026-11-07T00:00:00.000Z", tables: table([101]).tables, unverified: null };
    P.seedPm(sid, P.pm({ tag: "PM-cliRace", issues: [100], sequence: seq }));
    const { r, fired } = sideRun(sid, table([100, 102]), { archived_at: "2026-11-09T00:00:00.000Z" });
    assert.ok(fired, "the forge was not asked, so the race never fired");
    failed(r);
    assert.match(text(r), /changed while set-sequence ran/, brief(r));
    assert.deepStrictEqual(seqOf(sid), seq, "a refused write replaced the earlier table");
  });
  test("Q18 pm.issues changed during the forge query: refused, the earlier table is kept", () => {
    const sid = P.uuid(0x29416302);
    const seq = { updated_at: "2026-11-07T00:00:00.000Z", tables: table([101]).tables, unverified: null };
    P.seedPm(sid, P.pm({ tag: "PM-cliRaceIss", issues: [100], sequence: seq }));
    const { r, fired } = sideRun(sid, table([100, 102]), { issues: [{ number: 100 }, { number: 300 }] });
    assert.ok(fired, "the forge was not asked, so the race never fired");
    failed(r);
    assert.match(text(r), /the assignment changed while set-sequence ran; retry/, brief(r));
    assert.deepStrictEqual(seqOf(sid), seq, "a refused write replaced the earlier table");
    retire(sid);
  });
  test("Q18 only the order of pm.issues changed during the forge query: the table is written", () => {
    const sid = P.uuid(0x29416303);
    const seq = { updated_at: "2026-11-07T00:00:00.000Z", tables: table([101]).tables, unverified: null };
    P.seedPm(sid, P.pm({ tag: "PM-cliRaceOrd", issues: [100, 300], sequence: seq }));
    const { r, fired } = sideRun(sid, table([100, 300]), { issues: [{ number: 300 }, { number: 100 }] });
    assert.ok(fired, "the forge was not asked, so the race never fired");
    assert.strictEqual(r.code, 0, brief(r));
    assert.deepStrictEqual(tablesOf(sid), table([100, 300]).tables);
    assert.deepStrictEqual(P.readPm(sid).issues, [{ number: 300 }, { number: 100 }]);
    retire(sid);
  });
  test("Q18 pm.issues shrank during the forge query: refused, the earlier table is kept", () => {
    const sid = P.uuid(0x29416304);
    const seq = { updated_at: "2026-11-07T00:00:00.000Z", tables: table([101]).tables, unverified: null };
    P.seedPm(sid, P.pm({ tag: "PM-cliRaceShr", issues: [100, 300], sequence: seq }));
    const { r, fired } = sideRun(sid, table([100]), { issues: [{ number: 100 }] });
    assert.ok(fired, "the forge was not asked, so the race never fired");
    failed(r);
    assert.match(text(r), /the assignment changed while set-sequence ran; retry/, brief(r));
    assert.deepStrictEqual(seqOf(sid), seq, "a refused write replaced the earlier table");
    retire(sid);
  });
}

// required — each issue needs a non-blank reason and blocked_by / conflicts arrays (empty is fine).
function required(F, rejected, set) {
  const one = (issue) => ({ tables: [{ title: "t", waves: [{ issues: [{ number: 100, reason: "r", blocked_by: [], conflicts: [] }, issue] }] }] });
  const base = { number: 101, reason: "r", blocked_by: [], conflicts: [] };
  const drop = (k) => { const o = Object.assign({}, base); delete o[k]; return o; };
  for (const [label, issue, field] of [
    ["an empty reason", Object.assign({}, base, { reason: "" }), "reason"],
    ["a whitespace-only reason", Object.assign({}, base, { reason: "  \t" }), "reason"],
    ["no blocked_by", drop("blocked_by"), "blocked_by"],
    ["no conflicts", drop("conflicts"), "conflicts"],
  ]) {
    rejected(`Q14 ${label} is refused at its position without a forge call`, SID.A, one(issue), (r, t) => {
      assert.ok(t.includes(`tables[0].waves[0].issues[1] is missing ${field}`), brief(r));
      assert.strictEqual(r.calls.length, 0, JSON.stringify(r.calls));
    });
  }
  test("Q14 empty blocked_by and conflicts pass", () => assert.strictEqual(set(SID.A, one(base)).code, 0));
  refs(rejected, set, one, base);
}

// refs — every blocked_by / conflicts element is an issue ref {number, repo?}, the shape of a table issue.
function refs(rejected, set, one, base) {
  const BAD = ["abc", 0, { number: -1 }, { number: 0 }, null, { number: 1.5 }, {}, { number: "5" }, { number: 5, repo: "" }, { number: 5, repo: 3 }, 5];
  for (const field of ["blocked_by", "conflicts"]) {
    for (const bad of BAD) {
      rejected(`Q19 ${field} element ${JSON.stringify(bad)} is refused at its position without a forge call`, SID.A, one(Object.assign({}, base, { [field]: [bad] })), (r) => {
        assert.strictEqual(r.code, 1, brief(r));
        assert.ok(r.err.includes(`tables[0].waves[0].issues[1].${field}[0]`), brief(r));
        assert.strictEqual(r.calls.length, 0, JSON.stringify(r.calls));
      });
    }
  }
  test("Q19 well-formed blocked_by / conflicts refs pass (their range is not checked)", () => {
    const r = set(SID.A, one(Object.assign({}, base, { blocked_by: [{ number: 100 }], conflicts: [{ number: 100, repo: "o/r" }] })));
    assert.strictEqual(r.code, 0, brief(r));
  });
}

// caller — the caller check runs before the forge; --file xor --revalidate.
function caller(F, rejected) {
  rejected("Q15 another PM's --session is refused before the forge", SID.B, table([200]), (r, t) => {
    assert.strictEqual(r.code, 1, brief(r));
    assert.ok(t.includes("set-sequence writes only the calling PM's table"), brief(r));
    assert.strictEqual(r.calls.length, 0, JSON.stringify(r.calls));
  }, { caller: SID.A });
  test("Q15 no caller session id exits 2", () => {
    const r = F.run(["set-sequence", "--session", SID.A, "--file", F.seqFile(table([100]))]);
    assert.strictEqual(r.code, 2, brief(r));
  });
  test("Q15 --file and --revalidate together, or neither, exit 2", () => {
    for (const args of [["--file", F.seqFile(table([100])), "--revalidate"], []]) {
      const r = F.run(["set-sequence", ...args], { caller: SID.A });
      assert.strictEqual(r.code, 2, `${args.join(" ")}: ${brief(r)}`);
    }
  });
  test("Q16 --revalidate clears the unverified mark when the check passes; a failing one keeps it", () => {
    const sid = P.uuid(0x29416201);
    const mark = { reason: "timeout", at: "2026-11-07T00:00:00.000Z" };
    const seq = { updated_at: "2026-11-07T00:00:00.000Z", tables: table([101]).tables, unverified: mark };
    P.seedPm(sid, P.pm({ tag: "PM-cliRv", issues: [9201], sequence: seq }));
    const bad = F.run(["set-sequence", "--revalidate"], { caller: sid, env: { PM_FAKE_GH_MODE: "fail" } });
    assert.strictEqual(bad.code, 1, brief(bad));
    assert.deepStrictEqual(seqOf(sid).unverified, mark, "a failed revalidate dropped the mark");
    const st = P.raw(sid);
    st.pm.issues = [{ number: 100 }];
    P.writeRaw(sid, st);
    const r = F.run(["set-sequence", "--revalidate"], { caller: sid });
    assert.strictEqual(r.code, 0, brief(r));
    assert.strictEqual(seqOf(sid).unverified, null);
    assert.deepStrictEqual(seqOf(sid).tables, seq.tables);
    const end = P.raw(sid);
    end.pm.archived_at = "2026-11-09T00:00:00.000Z";
    P.writeRaw(sid, end);
  });
  test("Q16 rewriting with --file also clears the mark", () => {
    const sid = P.uuid(0x29416202);
    P.seedPm(sid, P.pm({ tag: "PM-cliRf", issues: [9202], sequence: { updated_at: null, tables: [], unverified: { reason: "timeout", at: "2026-11-07T00:00:00.000Z" } } }));
    const r = F.run(["set-sequence", "--file", F.seqFile(table([9202]))], { caller: sid });
    assert.strictEqual(r.code, 0, brief(r));
    assert.strictEqual(seqOf(sid).unverified, null);
  });
}

// limits(F) — owner/repo refs in a table and the 50-ref chunks of the batched query.
function limits(F) {
  const set = setter(F);
  const withRefs = (issues) => ({ tables: [{ title: "order", waves: [{ issues: issues.map((i) => Object.assign({ reason: "fixture", blocked_by: [], conflicts: [] }, i)) }] }] });
  test("Q10 an issue written as o/r#300 is the assigned #300", () => {
    const payload = withRefs([{ number: 300, repo: "o/r" }]);
    const r = set(SID.A, payload);
    assert.strictEqual(r.code, 0, brief(r));
    assert.deepStrictEqual(tablesOf(SID.A), payload.tables);
  });
  test("Q11 a cross-repo child (x/y#900 under meta o/r#100) is in range", () => {
    const payload = withRefs([{ number: 100 }, { number: 900, repo: "x/y" }]);
    const r = set(SID.A, payload);
    assert.strictEqual(r.code, 0, brief(r));
    assert.deepStrictEqual(tablesOf(SID.A), payload.tables);
  });
  const chains = (n) => table(Array.from({ length: n }, (_, i) => 1000 + i));
  test("Q12 25 issues under the meta are one forge call", () => {
    const r = set(SID.A, chains(25));
    assert.strictEqual(r.code, 0, brief(r));
    assert.strictEqual(r.checkCalls.length, 1, `forge calls: ${r.calls.length}`);
  });
  test(`Q13 ${CAP_CHAINS} issues are split into two forge calls of at most 50`, () => {
    const r = set(SID.A, chains(CAP_CHAINS));
    assert.strictEqual(r.code, 0, brief(r));
    assert.strictEqual(r.checkCalls.length, 2, `forge calls: ${r.calls.length}`);
    assert.deepStrictEqual(tablesOf(SID.A), chains(CAP_CHAINS).tables);
  });
}

module.exports = { sequence, limits };
