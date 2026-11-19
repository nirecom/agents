"use strict";
// Schema and scan cases of tests/hooks/feature-2941-pm-writer.js (#2941). No case markers.
// Assumed API: schema.js hasPmMark(state) / isActivePm(state) -> boolean; scan.js tagInUse(tag),
// directHoldersOf({number, repo?}, opts) -> [{tag, session_id, assigned_at}], assignedAt(pm, ref) -> at,
// isCurrentGeneration(sid) -> boolean, listPmTags() -> [tag], listActivePms() -> [{tag, session_id, ...}].
const assert = require("node:assert");
const { test } = require("node:test");
const W = require("./fixture");
const { P } = W;

const scan = () => P.load("hooks/pm-session/scan.js");
const schema = () => P.load("hooks/pm-session/schema.js");

function keyCases() {
  test("S1 PERSISTED_TOP_LEVEL_KEYS registers pm (every state write throws otherwise)", () => {
    assert.ok(P.persistedKeys().includes("pm"), JSON.stringify(P.persistedKeys()));
  });
  test("S1 a state with pm survives a normal state write", () => {
    const sid = W.nextSid();
    P.seedPm(sid, P.pm({ tag: W.nextTag("PM-io"), issues: [7001] }));
    P.io().markStep(sid, "workflow_init", "in_progress");
    assert.strictEqual(P.wfInitStatus(sid), "in_progress", "the write did not land");
    assert.deepStrictEqual(W.nums(P.readPm(sid)), [7001]);
  });
}

function schemaCases() {
  test("S2 hasPmMark / isActivePm split archived from active", () => {
    const s = schema();
    const act = { pm: P.pm({ issues: [1] }) };
    const arc = { pm: P.pm({ issues: [], archived_at: "2026-11-02T00:00:00.000Z" }) };
    assert.deepStrictEqual([s.hasPmMark({}), s.hasPmMark(act), s.hasPmMark(arc)], [false, true, true]);
    assert.deepStrictEqual([s.isActivePm({}), s.isActivePm(act), s.isActivePm(arc)], [false, true, false]);
    assert.deepStrictEqual([s.hasPmMark(null), s.isActivePm(null)], [false, false]);
  });
  test("S2 pm: [] is not a PM mark", () => {
    const s = schema();
    assert.deepStrictEqual([s.hasPmMark({ pm: [] }), s.isActivePm({ pm: [] })], [false, false]);
  });
}

function scanCases() {
  const tagA = W.nextTag("PM-scanA");
  const tagB = W.nextTag("PM-scanB");
  const oldA = W.nextSid();
  const curA = W.nextSid();
  const arcB = W.nextSid();
  const seed = () => {
    if (P.exists(curA)) return;
    P.seedPm(oldA, P.pm({ tag: tagA, issues: [7101], current_since: "2026-11-01T00:00:00.000Z" }));
    P.seedPm(curA, P.pm({ tag: tagA, issues: [7101, 7102], current_since: "2026-11-04T00:00:00.000Z", upstream_session_id: oldA }));
    P.seedPm(arcB, P.pm({ tag: tagB, issues: [7201], archived_at: "2026-11-02T00:00:00.000Z" }));
  };
  test("S3 tagInUse is case-insensitive and counts archived PMs", () => {
    seed();
    assert.strictEqual(scan().tagInUse(tagA.toLowerCase()), true);
    assert.strictEqual(scan().tagInUse(tagB.toUpperCase()), true);
    assert.strictEqual(scan().tagInUse("PM-never-used-2941"), false);
  });
  const holders = (n) => scan().directHoldersOf({ number: n }, {}).map((h) => ({ tag: h.tag, session_id: h.session_id }));
  test("S4 directHoldersOf answers the current generation of an active PM only", () => {
    seed();
    assert.deepStrictEqual(holders(7102), [{ tag: tagA, session_id: curA }]);
    assert.deepStrictEqual(holders(7101), [{ tag: tagA, session_id: curA }], "the old generation must not answer");
    assert.deepStrictEqual(holders(7201), [], "an archived PM holds nothing");
    assert.deepStrictEqual(holders(7999), []);
  });
  test("S4 directHoldersOf returns every PM that holds the issue directly, with assigned_at", () => {
    const a = { sid: W.nextSid(), tag: W.nextTag("PM-dhA") };
    const b = { sid: W.nextSid(), tag: W.nextTag("PM-dhB") };
    P.seedPm(a.sid, P.pm({ tag: a.tag, issues: [7401] }));
    P.seedPm(b.sid, P.pm({ tag: b.tag, issues: [7401, 7402] }));
    const got = scan().directHoldersOf({ number: 7401 }, {});
    assert.deepStrictEqual(got.map((h) => h.tag).sort(), [a.tag, b.tag].sort(), JSON.stringify(got));
    assert.ok(got.every((h) => typeof h.assigned_at === "string"), JSON.stringify(got));
  });
  test("S8 assignedAt is the last init/add at, a remove resets it until the next add, inherit does not count", () => {
    const fn = scan().assignedAt;
    assert.strictEqual(typeof fn, "function", "scan.assignedAt is missing");
    const e = (op, at, n) => ({ at, op, issues: [{ number: n }], reason: "r" });
    const log = [e("init", "2026-11-01T00:00:00.000Z", 7501), e("remove", "2026-11-02T00:00:00.000Z", 7501), e("add", "2026-11-03T00:00:00.000Z", 7501), e("inherit", "2026-11-04T00:00:00.000Z", 7501)];
    assert.strictEqual(fn(P.pm({ issues: [7501], assignment_log: log }), { number: 7501 }), "2026-11-03T00:00:00.000Z");
    const onlyInherit = P.pm({ issues: [7502], current_since: "2026-11-06T00:00:00.000Z", assignment_log: [e("inherit", "2026-11-07T00:00:00.000Z", 7502)] });
    assert.strictEqual(fn(onlyInherit, { number: 7502 }), "2026-11-06T00:00:00.000Z", "no init/add: current_since");
  });
  test("S5 isCurrentGeneration decides by current_since, not mtime", () => {
    seed();
    P.writeRaw(oldA, P.raw(oldA)); // the old file is now the newest by mtime
    assert.strictEqual(scan().isCurrentGeneration(curA), true);
    assert.strictEqual(scan().isCurrentGeneration(oldA), false);
  });
  test("S6 listPmTags includes archived tags; listActivePms excludes them", () => {
    seed();
    const tags = scan().listPmTags();
    assert.ok(tags.includes(tagA) && tags.includes(tagB), JSON.stringify(tags));
    const act = scan().listActivePms().map((x) => x.tag);
    assert.ok(act.includes(tagA) && !act.includes(tagB), JSON.stringify(act));
  });
}

// legacyRootCases() — the scan covers every listStateRoots root, the legacy one included. The legacy
// root is listed only without a pin, so the scan runs in a child with both pins cleared for that one
// call and HOME / USERPROFILE at a fixture home: <home>/.workflow-state (new) and
// <home>/.claude/projects/workflow (legacy, state-dir-relocation/legacy.js LEGACY_ROOT).
function legacyRootCases() {
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  const cp = require("node:child_process");
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pm-legacy-home-"));
  const newRoot = path.join(home, ".workflow-state");
  const legacyRoot = path.join(home, ".claude", "projects", "workflow");
  for (const d of [newRoot, legacyRoot]) fs.mkdirSync(d, { recursive: true });
  const tagLeg = W.nextTag("PM-legOld");
  const tagArc = W.nextTag("PM-legArc");
  const tagNew = W.nextTag("PM-legNew");
  const sid = { leg: W.nextSid(), arc: W.nextSid(), newOld: W.nextSid(), newCur: W.nextSid() };
  // place(s, root, pmValue) — seeded through the pinned writer, then moved into the fixture root.
  const place = (s, root, pmValue) => {
    P.seedPm(s, pmValue);
    fs.copyFileSync(P.statePath(s), path.join(root, `${s}.json`));
    fs.rmSync(P.statePath(s), { force: true });
  };
  place(sid.leg, legacyRoot, P.pm({ tag: tagLeg, issues: [7301] }));
  place(sid.arc, legacyRoot, P.pm({ tag: tagArc, issues: [], archived_at: "2026-11-02T00:00:00.000Z" }));
  place(sid.newOld, legacyRoot, P.pm({ tag: tagNew, issues: [7302], current_since: "2026-10-01T00:00:00.000Z" }));
  place(sid.newCur, newRoot, P.pm({ tag: tagNew, issues: [7302], current_since: "2026-11-05T00:00:00.000Z", upstream_session_id: sid.newOld }));

  const probe = [
    "const s = require(process.argv[1]); const a = JSON.parse(process.argv[2]);",
    "const own = (n) => { const o = s.directHoldersOf({ number: n }, {})[0]; return o ? { tag: o.tag, session_id: o.session_id } : null; };",
    "process.stdout.write(JSON.stringify({",
    "  legInUse: s.tagInUse(a.tagLeg.toLowerCase()), arcInUse: s.tagInUse(a.tagArc), owner7301: own(7301), owner7302: own(7302),",
    "  tags: s.listPmTags(), active: s.listActivePms().map((x) => x.tag),",
    "  legCurrent: s.isCurrentGeneration(a.leg), newOldCurrent: s.isCurrentGeneration(a.newOld),",
    "}));",
  ].join("\n");
  let result = null;
  const run = () => {
    if (result) return result;
    const env = Object.assign({}, process.env, { HOME: home, USERPROFILE: home });
    for (const k of ["WORKFLOW_STATE_DIR", "WORKFLOW_PLANS_DIR", "CLAUDE_CODE_SESSION_ID"]) delete env[k];
    const args = JSON.stringify({ tagLeg, tagArc, leg: sid.leg, newOld: sid.newOld });
    const r = cp.spawnSync(process.execPath, ["-e", probe, path.join(P.ROOT, "hooks", "pm-session", "scan.js"), args], { encoding: "utf8", timeout: 20000, cwd: home, env });
    try { result = { ok: true, v: JSON.parse(r.stdout) }; } catch (_) { result = { ok: false, why: `code=${r.status} out=${r.stdout} err=${String(r.stderr).split("\n").slice(0, 3).join(" | ")}` }; }
    return result;
  };
  const v = () => { const r = run(); assert.ok(r.ok, r.why); return r.v; };
  require("node:test").after(() => fs.rmSync(home, { recursive: true, force: true }));

  test("S7 fixture: the new root and the legacy root both hold the seeded files", () => {
    for (const [s, root] of [[sid.leg, legacyRoot], [sid.arc, legacyRoot], [sid.newOld, legacyRoot], [sid.newCur, newRoot]]) {
      assert.ok(fs.existsSync(path.join(root, `${s}.json`)), `${s} in ${root}`);
    }
  });
  test("S7 a tag held only in the legacy root is in use (active and archived alike)", () => {
    const x = v();
    assert.deepStrictEqual([x.legInUse, x.arcInUse], [true, true], JSON.stringify(x));
    assert.ok(x.tags.includes(tagLeg) && x.tags.includes(tagArc) && x.tags.includes(tagNew), JSON.stringify(x.tags));
  });
  test("S7 directHoldersOf and listActivePms see an active PM in the legacy root", () => {
    const x = v();
    assert.deepStrictEqual(x.owner7301, { tag: tagLeg, session_id: sid.leg });
    assert.ok(x.active.includes(tagLeg) && !x.active.includes(tagArc), JSON.stringify(x.active));
  });
  test("S7 generations are decided across roots: the new-root file beats its legacy-root old generation", () => {
    const x = v();
    assert.deepStrictEqual(x.owner7302, { tag: tagNew, session_id: sid.newCur });
    assert.deepStrictEqual([x.legCurrent, x.newOldCurrent], [true, false], JSON.stringify(x));
  });
}

module.exports = { keyCases, schemaCases, scanCases, legacyRootCases };
