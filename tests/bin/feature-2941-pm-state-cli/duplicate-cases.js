"use strict";
// Duplicate-issue cases of tests/bin/feature-2941-pm-state-cli.js (#2941). No case markers.
// checkSequence runs in-process against a recording ancestry (no forge), then once through
// `bin/pm-state set-sequence` with the fake gh call log.
const assert = require("node:assert");
const { test } = require("node:test");
const { P } = require("./fixture");
const { SID } = require("./world");

const HOME = "o/r";
const item = (ref, extra) => Object.assign({ reason: "r", blocked_by: [], conflicts: [] }, typeof ref === "object" ? ref : { number: ref }, extra || {});
const table = (title, ...ws) => ({ title, waves: ws.map((issues) => ({ issues: issues.map((i) => item(i)) })) });
const waves = (...ws) => [table("t", ...ws)];

// check(tables, homeRepo, ownerIssues) -> {r, prefetch, holders}: the verdict and how often the forge side was asked.
function check(tables, homeRepo, ownerIssues) {
  const { checkSequence } = P.load("bin/lib/pm-state/sequence.js");
  const seen = { prefetch: 0, holders: 0 };
  const ancestry = {
    prefetch: () => { seen.prefetch += 1; },
    holdersOf: (ref, holders) => { seen.holders += 1; return { ok: true, direct: holders, viaMeta: [] }; },
  };
  const owner = { tag: "PM-dup", session_id: null, issues: ownerIssues || [{ number: 5 }, { number: 6 }, { number: 5, repo: "other/x" }] };
  const r = checkSequence(tables, owner, { ancestry, homeRepo: homeRepo === undefined ? HOME : homeRepo });
  return Object.assign({ r }, seen);
}

function duplicateRefused(x, label) {
  assert.strictEqual(x.r.ok, false, JSON.stringify(x.r));
  assert.strictEqual(x.r.kind, "structure", JSON.stringify(x.r));
  assert.ok(String(x.r.reason).startsWith("duplicate issue in the sequence"), JSON.stringify(x.r));
  assert.ok(String(x.r.reason).includes(label), JSON.stringify(x.r));
  assert.deepStrictEqual([x.prefetch, x.holders], [0, 0], "a duplicate refusal asked the forge");
}

function duplicates(F) {
  test("D1 #5 in wave 1 and o/r#5 in wave 2 is a duplicate: structure, no forge call", () => {
    const x = check(waves([5], [{ number: 5, repo: HOME }]));
    duplicateRefused(x, "o/r#5");
    assert.deepStrictEqual(x.r.issues, [{ number: 5, repo: HOME }]);
  });
  test("D1 the repo of a duplicate is compared case-insensitively", () => {
    const x = check(waves([5], [{ number: 5, repo: "O/R" }]));
    duplicateRefused(x, "#5");
    assert.deepStrictEqual(x.r.issues, [{ number: 5, repo: "O/R" }]);
  });
  test("D2 the same issue twice in one wave is a duplicate", () => {
    const x = check(waves([5, 6, 5]));
    duplicateRefused(x, "o/r#5");
    assert.deepStrictEqual(x.r.issues, [{ number: 5, repo: HOME }]);
  });
  test("D2 an issue named three times is reported once; every duplicated issue is reported", () => {
    const x = check(waves([5, 5, 5], [6, 6]));
    duplicateRefused(x, "o/r#5");
    assert.deepStrictEqual(x.r.issues, [{ number: 5, repo: HOME }, { number: 6, repo: HOME }]);
    assert.strictEqual(x.r.reason, "duplicate issue in the sequence: o/r#5 o/r#6", JSON.stringify(x.r));
  });
  test("D2 #5 in one table and o/r#5 in another table is a duplicate across tables", () => {
    const x = check([table("a", [5]), table("b", [{ number: 5, repo: HOME }])]);
    duplicateRefused(x, "o/r#5");
    assert.deepStrictEqual(x.r.issues, [{ number: 5, repo: HOME }]);
  });
  test("D3 a repo-unknown ref is still repo-unknown, never reported as a duplicate", () => {
    const x = check(waves([5], [5]), null);
    assert.strictEqual(x.r.ok, false, JSON.stringify(x.r));
    assert.strictEqual(x.r.kind, "unresolvable", JSON.stringify(x.r));
    assert.strictEqual(x.r.reason, "repo-unknown", JSON.stringify(x.r));
    assert.ok(!/duplicate/.test(x.r.reason), JSON.stringify(x.r));
  });
  test("D4 an issue named again in blocked_by / conflicts is not a duplicate", () => {
    const tables = [{ title: "t", waves: [
      { issues: [item(5, { conflicts: [{ number: 6 }] })] },
      { issues: [item(6, { blocked_by: [{ number: 5 }, { number: 5, repo: HOME }], conflicts: [{ number: 5 }] })] },
    ] }];
    const x = check(tables);
    assert.deepStrictEqual(x.r, { ok: true });
  });
  test("D5 o/r#5 and other/x#5 across waves are distinct issues, not duplicates", () => {
    const x = check(waves([{ number: 5, repo: HOME }], [{ number: 5, repo: "other/x" }]));
    assert.deepStrictEqual(x.r, { ok: true });
    assert.strictEqual(x.holders, 2, "each distinct issue is range-checked");
  });
  test("D6 set-sequence refuses a duplicate as structure without a forge call and keeps pm", () => {
    const before = JSON.stringify(P.readPm(SID.A));
    const payload = { tables: waves([100], [{ number: 100, repo: HOME }]) };
    const r = F.run(["set-sequence", "--session", SID.A, "--file", F.seqFile(payload)], { caller: SID.A });
    const brief = `code=${r.code} out=${r.out} err=${r.err}`;
    assert.strictEqual(r.code, 1, brief);
    assert.ok(`${r.out}\n${r.err}`.includes("structure: duplicate issue in the sequence"), brief);
    assert.strictEqual(r.calls.length, 0, JSON.stringify(r.calls));
    assert.strictEqual(JSON.stringify(P.readPm(SID.A)), before, "pm changed on a refused write");
  });
}

module.exports = { duplicates };
