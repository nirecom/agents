"use strict";
// show / list / owner cases of tests/bin/feature-2941-pm-state-cli.js (#2941). No case markers.
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const { nums, P } = require("./fixture");
const { SID, TAG } = require("./world");

const brief = (r) => `code=${r.code} out=${r.out} err=${r.err}`;
const ok = (r) => assert.strictEqual(r.code, 0, brief(r));
const failed = (r) => assert.ok(r.code !== 0 && r.code !== null && r.code !== 127 && r.err.trim().length > 0, brief(r));

function show(F) {
  test("C1 show of the current active PM: tag, issues, not archived, current", () => {
    const r = F.run(["show", "--session", SID.A]);
    ok(r);
    assert.strictEqual(r.json.tag, TAG.A, brief(r));
    assert.deepStrictEqual(nums(r.json.issues), [100, 300]);
    assert.strictEqual(r.json.archived, false);
    assert.strictEqual(r.json.current, true);
  });
  test("C1 show also prints the sequence, its unverified mark and reason included", () => {
    const sid = P.uuid(0x29416101);
    const seq = { updated_at: "2026-11-07T00:00:00.000Z", tables: [{ title: "t", waves: [] }], unverified: { reason: "timeout", at: "2026-11-07T00:00:00.000Z" } };
    P.seedPm(sid, P.pm({ tag: "PM-cliShow", issues: [9101], sequence: seq, archived_at: "2026-11-08T00:00:00.000Z" }));
    const r = F.run(["show", "--session", sid]);
    ok(r);
    assert.deepStrictEqual(r.json.sequence, seq, brief(r));
    assert.deepStrictEqual(Object.keys(r.json).sort(), ["archived", "current", "issues", "sequence", "tag"], brief(r));
  });
  test("C2 show of an old generation says current=false", () => {
    const r = F.run(["show", "--session", SID.Aold]);
    ok(r);
    assert.strictEqual(r.json.current, false, brief(r));
  });
  test("C3 show of an archived PM says archived=true", () => {
    const r = F.run(["show", "--session", SID.C]);
    ok(r);
    assert.strictEqual(r.json.archived, true, brief(r));
  });
  test("C4 show of a session without a PM prints {pm:null}", () => {
    const r = F.run(["show", "--session", SID.D]);
    ok(r);
    assert.deepStrictEqual(r.json, { pm: null }, brief(r));
  });
  test("C5 list prints every tag, archived included", () => {
    const r = F.run(["list"]);
    ok(r);
    const tags = (Array.isArray(r.json) ? r.json : (r.json && r.json.tags) || []).map((t) => (typeof t === "object" ? t.tag : t));
    for (const t of [TAG.A, TAG.B, TAG.C]) assert.ok(tags.includes(t), `${t} missing: ${brief(r)}`);
  });
}

const own = (r, tag, sid) => {
  ok(r);
  assert.deepStrictEqual(r.json && { tag: r.json.tag, session_id: r.json.session_id }, { tag, session_id: sid }, brief(r));
};
const none = (r) => { ok(r); assert.deepStrictEqual(r.json, { pm: null }, brief(r)); };

// #2942: owner reads the Projects v2 PM field (the issue's own value, else its nearest ancestor's) in
// one forge read; the local assignment lists, meta labels and assignedAt / tag order no longer decide.
function owner(F) {
  test("O1 an issue whose own PM field names a PM answers it in one forge read", () => {
    const r = F.run(["owner", "--issue", "#300"]);
    own(r, TAG.A, SID.A);
    assert.strictEqual(r.calls.length, 1, JSON.stringify(r.calls));
  });
  test("O2 a child and a grandchild answer through their ancestor's field; label overflow above no longer matters", () => {
    own(F.run(["owner", "--issue", "#101"]), TAG.A, SID.A);
    own(F.run(["owner", "--issue", "#102"]), TAG.A, SID.A); own(F.run(["owner", "--issue", "#301"]), TAG.A, SID.A);
  });
  test("O3 under two fields in the chain the nearest ancestor's wins", () => own(F.run(["owner", "--issue", "#202"]), TAG.B, SID.B));
  test("O3 the issue's own field beats an ancestor's, in one forge read", () => {
    const r = F.run(["owner", "--issue", "#103"]);
    own(r, TAG.F, SID.F);
    assert.strictEqual(r.calls.length, 1, JSON.stringify(r.calls));
  });
  test("O3 two local holders: the field decides, not the earlier assignedAt", () => own(F.run(["owner", "--issue", "#970"]), TAG.late, SID.late));
  test("O3 two local holders at the same time: the field decides, not the code-point order", () => own(F.run(["owner", "--issue", "#960"]), TAG.tieB, SID.tieB));
  test("O4 an issue with no field in its chain answers {pm:null}", () => none(F.run(["owner", "--issue", "#500"])));
  test("O4 a child of a plain issue with a field inherits it (nearest ancestor, meta or not)", () => own(F.run(["owner", "--issue", "x/y#951"]), TAG.E, SID.E));
  for (const [label, ref] of [["an archived PM", "#400"], ["an old generation only", "#150"]]) {
    test(`O5 an issue held by ${label} answers {pm:null}`, () => none(F.run(["owner", "--issue", ref])));
  }
  for (const [label, ref] of [["a forge failure", "#800"], ["a cycle", "#600"], ["a chain deeper than the cap", "#700"]]) {
    test(`O6 ${label} exits non-zero with the reason on stderr`, () => failed(F.run(["owner", "--issue", ref])));
  }
  test("O7 with no PM state at all: no field answers {pm:null}; a field tag no local state holds is undecidable", () => {
    const empty = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "pm-empty-"));
    for (const d of ["state", "plans"]) fs.mkdirSync(path.join(empty, d));
    try {
      const env = { WORKFLOW_STATE_DIR: path.join(empty, "state"), WORKFLOW_PLANS_DIR: path.join(empty, "plans") }, r = F.run(["owner", "--issue", "#500"], { env });
      none(r);
      const u = F.run(["owner", "--issue", "#101"], { env }); failed(u); assert.match(u.err, /tag-not-local/, brief(u));
    } finally {
      fs.rmSync(empty, { recursive: true, force: true });
    }
  });
}

// refs(F) — `#N` takes the cwd origin's repo (o/r); `owner/repo#N` names its repo; both compare as
// one issue, and a parent's repo comes from the forge (nameWithOwner), so a chain may cross repos.
function refs(F) {
  test("R1 o/r#300 is the same issue as #300: its PM answers in one forge read", () => {
    const r = F.run(["owner", "--issue", "o/r#300"]);
    own(r, TAG.A, SID.A);
    assert.strictEqual(r.calls.length, 1, JSON.stringify(r.calls));
  });
  test("R2 an issue of another repo is read in that repo: x/y#950 answers its PM in one forge read", () => {
    const r = F.run(["owner", "--issue", "x/y#950"]);
    own(r, TAG.E, SID.E);
    assert.ok(r.calls.length === 1 && /owner: "x", name: "y"/.test(r.calls[0].join(" ")), JSON.stringify(r.calls));
  });
  test("R3 #950 (o/r) is not x/y#950: no direct hit, and the forge is asked about o/r", () => {
    const r = F.run(["owner", "--issue", "#950"]);
    none(r);
    assert.ok(r.calls.some((a) => /\bowner\s*[:=]\s*\\?"?o\b/.test(a.join(" "))), JSON.stringify(r.calls));
  });
  test("R4 x/y#100 is not the assigned o/r#100: no direct hit, root without an owner", () => none(F.run(["owner", "--issue", "x/y#100"])));
  test("R5 a cross-repo parent (x/y#900 -> meta o/r#100) answers the PM of o/r#100", () => own(F.run(["owner", "--issue", "x/y#900"]), TAG.A, SID.A));
}

module.exports = { show, owner, refs };
