"use strict";
// Tests: bin/lib/pm-state/owner.js, bin/lib/pm-notify/common.js, bin/lib/pm-notify/next.js, bin/lib/pm-notify/settle.js, bin/lib/pm-notify/inbox.js, bin/workflow/lib/workflow-init/phases/pm-scan.js
// Tags: TL2, scope:issue-specific, pm-session, pm-notify, pm-field, issue-3135, issue-3168, batched-owner
// #3135: the notification layer never discards on an owner answer it cannot trust. resolveOwner adds
// fieldAbsent:true to {ok:true, owner:null} when the chain's board has no `pm` field; the owner gate makes that,
// and "owner null while a local active PM state holds the issue or an ancestor", undecidable for every verb
// that drops on no-owner (inbox unassigned, next, settle, pm-scan's ownerless record). The inbox drift check
// reports a field-less board in one line instead of a drift per issue.
// TL3 gap (what this test does NOT catch):
// - a real GitHub board without the `pm` field; the fake gh answers its shape (noPmFieldBoard / noPmField).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
const cwd0 = process.cwd();
process.chdir(X.F.home);
after(() => { process.chdir(cwd0); restore(); });

const scan = require(P.ROOT + "/hooks/pm-session/scan");
const owner = () => P.load("bin/lib/pm-state/owner.js");
const NEXT = () => P.load("bin/lib/pm-notify/next.js");
const SETTLE = () => P.load("bin/lib/pm-notify/settle.js");
const INBOX = () => P.load("bin/lib/pm-notify/inbox.js");
const SCAN = () => P.load("bin/workflow/lib/workflow-init/phases/pm-scan.js");

let n = 0;
const sid = () => P.uuid(0x31350000 + (++n));
const ref = (num) => ({ number: num, repo: "o/r" });
const at = (num) => `o/r#${num}`;
const own = (nums) => nums.map((num) => ({ number: num, repo: "o/r" }));
const brief = (r) => JSON.stringify(r).slice(0, 600);
const ORIGIN = "https://github.com/o/r.git";

// 9101 real field-less board, 9106 field null in data, 9102 / 9104 held by PM-hold with an empty field, 9105 a
// child of 9104, 9103 empty and held by nobody, 9107 owned by PM-hold through the field.
G.setMap({
  [at(9101)]: { noPmFieldBoard: true }, [at(9106)]: { noPmField: true }, [at(9102)]: {}, [at(9104)]: {},
  [at(9105)]: { parent: { number: 9104, repo: "o/r" } }, [at(9103)]: {}, [at(9107)]: { pm: "PM-hold" },
  [at(9108)]: { noPmFieldBoard: true }, [at(9109)]: { noPmField: true },
});
const HOLD = sid();
P.seedPm(HOLD, P.pm({ tag: "PM-hold", issues: own([9102, 9104, 9107]) }));
const UNTRUSTED = [9101, 9106, 9102, 9105];
const entries = () => scan.listPmFiles();

caseBegin("owner-field-absent-mark", "bin/lib/pm-state/owner.js");
test("O1 a field-less board answers owner null with fieldAbsent, both in GitHub's shape and as data null", () => {
  for (const num of [9101, 9106]) {
    const r = owner().resolveOwner(ref(num), { scan, entries: entries() });
    assert.deepStrictEqual([r.ok, r.owner, r.fieldAbsent], [true, null, true], `${num}: ${brief(r)}`);
  }
});
test("O2 an empty field on a board that has it is owner null without the mark", () => {
  const r = owner().resolveOwner(ref(9103), { scan, entries: entries() });
  assert.deepStrictEqual([r.ok, r.owner, Boolean(r.fieldAbsent)], [true, null, false], brief(r));
});
caseEnd();

caseBegin("owner-gate-next", "bin/lib/pm-notify/next.js");
const target = (num) => NEXT().targetOf({ id: `t-${num}`, point: "start", issue: at(num) }, ref(num), { entries: entries(), records: {}, forgeState: false });
test("G1 next: field absent, or held locally (issue or ancestor) with owner null -> undecidable, never dropped", () => {
  for (const num of UNTRUSTED) {
    const t = target(num);
    assert.ok(!t.drop, `${num} was dropped: ${brief(t)}`);
    assert.ok(t.undecidable, `${num}: ${brief(t)}`);
    assert.ok(!(t.record && t.record.tag === null), `${num} kept an ownerless record: ${brief(t)}`);
  }
});
test("G2 next non-regression: no holder and an empty field is dropped; a field owner is sent to", () => {
  assert.strictEqual(target(9103).drop, "no-owner");
  const s = target(9107);
  assert.ok(s.send && s.send.tag === "PM-hold" && s.send.session === HOLD, brief(s));
});
caseEnd();

caseBegin("owner-gate-settle", "bin/lib/pm-notify/settle.js");
test("G3 settle: an untrusted owner null goes to unassigned with an undecidable reason, not no-owner", () => {
  for (const num of UNTRUSTED) {
    const b = SETTLE().boxOf({ id: `s-${num}`, point: "start", issue: at(num), tag: null }, entries());
    assert.strictEqual(b.name, "unassigned", `${num}: ${brief(b)}`);
    assert.doesNotMatch(String(b.reason), /^no-owner/, `${num}: ${brief(b)}`);
  }
});
test("G4 settle non-regression: no holder and an empty field is no-owner", () => {
  const b = SETTLE().boxOf({ id: "s-9103", point: "start", issue: at(9103), tag: null }, entries());
  assert.strictEqual(b.name, "unassigned");
  assert.match(String(b.reason), /^no-owner/);
});
caseEnd();

caseBegin("owner-gate-inbox", "bin/lib/pm-notify/inbox.js");
const entry = (num) => ({ id: `u-${num}`, point: "start", issue: at(num), from_session: HOLD, at: "2026-11-01T00:00:00.000Z" });
test("G5 inbox: unassigned notifications with an untrusted owner null stay in unassigned.jsonl", () => {
  const me = sid();
  P.seedPm(me, P.pm({ tag: "PM-inbox", issues: [] }));
  X.writeBox("unassigned", UNTRUSTED.concat([9103]).map(entry));
  INBOX().runInbox(me, { origin: ORIGIN, budgetMs: 60000 });
  const left = X.readBox("unassigned").map((e) => e.id);
  for (const num of UNTRUSTED) assert.ok(left.includes(`u-${num}`), `${num} was discarded: ${left}`);
  assert.ok(!left.includes("u-9103"), `an ownerless note with no holder stayed: ${left}`);
});
test("G6 inbox drift: a PM whose issues sit on a field-less board gets one field-absent line, no drift per issue", () => {
  const me = sid();
  P.seedPm(me, P.pm({ tag: "PM-drift", issues: own([9108, 9109]) }));
  X.writeBox("unassigned", []);
  const text = INBOX().runInbox(me, { origin: ORIGIN, budgetMs: 60000, drift: true });
  const lines = String(text).split("\n").filter(Boolean);
  assert.ok(!lines.some((l) => /drift: o\/r#910[89]/.test(l)), text);
  const absent = lines.filter((l) => /field/i.test(l) && /(absent|missing|not exist|has no|does not have)/i.test(l));
  assert.strictEqual(absent.length, 1, `expected one field-absent line: ${text}`);
});
// #3152: runInbox takes opts.spawnSync and hands it to every forge read it makes (unassigned owner, drift, meta);
// G5/G6 above run without it and keep today's real spawn. tap() delegates to the real spawn, so the fake gh on
// PATH still answers; every gh call the fake counted must have come through tap.
const cp = require("node:child_process");
function tap() {
  const seen = [];
  // gh is spawned directly or as `bash -c 'exec "$0" "$@"' gh …` (spawn-env.js buildGhSpawn).
  const isGh = (cmd, args) => /(^|[\\/])gh(\.exe|\.cmd)?$/i.test(String(cmd)) || (/(^|[\\/])bash(\.exe)?$/i.test(String(cmd)) && args[0] === "-c" && args[2] === "gh");
  const spawnSync = (cmd, args, opts) => { if (isGh(cmd, [].concat(args || []))) seen.push(cmd); return cp.spawnSync(cmd, args, opts); };
  return { spawnSync, ghCalls: () => seen.length };
}
test("G8 inbox with opts.spawnSync: the same outcome as G5/G6, and every gh call goes through it", () => {
  const me = sid();
  P.seedPm(me, P.pm({ tag: "PM-inbox-inj", issues: own([9108, 9109]) }));
  X.writeBox("unassigned", UNTRUSTED.concat([9103]).map(entry));
  const t = tap();
  const before = G.calls();
  const text = INBOX().runInbox(me, { origin: ORIGIN, budgetMs: 60000, drift: true, spawnSync: t.spawnSync });
  const made = G.calls() - before;
  const left = X.readBox("unassigned").map((e) => e.id);
  for (const num of UNTRUSTED) assert.ok(left.includes(`u-${num}`), `${num} was discarded: ${left}`);
  assert.ok(!left.includes("u-9103"), `an ownerless note with no holder stayed: ${left}`);
  assert.ok(made >= 1, `the inbox read no forge: ${text}`);
  assert.strictEqual(t.ghCalls(), made, `gh calls outside opts.spawnSync: fake saw ${made}, injected ${t.ghCalls()}`);
});
caseEnd();

caseBegin("owner-gate-spawn-injected", "bin/lib/pm-notify/common.js");
test("G9 decidedOwnerOf(ref, timeoutMs, entries, {spawnSync}) reads the owner through the injected spawn", () => {
  const t = tap();
  const before = G.calls();
  const r = P.load("bin/lib/pm-notify/common.js").decidedOwnerOf(ref(9107), 60000, entries(), { spawnSync: t.spawnSync });
  assert.deepStrictEqual([r.ok, r.owner && r.owner.tag], [true, "PM-hold"], brief(r));
  const made = G.calls() - before;
  assert.ok(made >= 1, brief(r));
  assert.strictEqual(t.ghCalls(), made, `gh calls outside opts.spawnSync: fake saw ${made}, injected ${t.ghCalls()}`);
});
caseEnd();

caseBegin("owner-gate-pm-scan", "bin/workflow/lib/workflow-init/phases/pm-scan.js");
test("G7 pm-scan writes no ownerless record for an untrusted owner null, so the start notification survives", () => {
  const s = sid();
  P.seedState(s);
  const state = { issues: UNTRUSTED.concat([9103]) };
  SCAN().pmScan(state, s);
  const records = P.raw(s).pm_owner_records || {};
  for (const num of UNTRUSTED) {
    const r = records[at(num)];
    assert.ok(!r || r.tag !== null, `${num} got an ownerless record: ${brief(records)}`);
  }
  assert.deepStrictEqual(records[at(9103)] && records[at(9103)].tag, null, `no ownerless record for 9103: ${brief(records)}`);
  SCAN().recordStart(state, s);
  const started = X.notes(s).filter((e) => e.point === "start").map((e) => String(e.issue).toLowerCase());
  for (const num of UNTRUSTED) assert.ok(started.includes(at(num)), `${num} lost its start notification: ${started}`);
  assert.ok(!started.includes(at(9103)), `an ownerless issue got a start notification: ${started}`);
});
caseEnd();

// #3168: the owner lookup becomes batched. resolveOwnersBatch returns a whole failure as {ok:false, reason} (distinguishable
// from per-ref failures), and common.ownersOf / decidedOwnersOf stand on top of it. The single-ref versions are one-ref batched calls
// sharing #3135's judgment (trustOf). Case bodies: feature-3135-pm-owner-gate/batched-cases.js.
const B = require("./feature-3135-pm-owner-gate/batched-cases");
const bctx = { test, assert, P, ref, brief, entries, scan, owner };
caseBegin("owner-batched-resolve", "bin/lib/pm-state/owner.js");
B.registerOwner(bctx);
caseEnd();

caseBegin("owner-batched-common", "bin/lib/pm-notify/common.js");
B.registerCommon(bctx);
caseEnd();

caseBegin("owner-batched-inbox", "bin/lib/pm-notify/inbox.js");
B.registerInbox(Object.assign({ X, INBOX, sid, ORIGIN }, bctx));
caseEnd();
