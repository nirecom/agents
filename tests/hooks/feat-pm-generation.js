"use strict";
// Tests: hooks/pm-session/pm-lock.js, hooks/pm-session/writer.js, hooks/pm-session/inherit.js, bin/lib/pm-state/cli.js, hooks/pm-session/rename.js, bin/lib/pm-state/owner.js, bin/lib/pm-notify/mailbox.js
// Tags: TL2, scope:common, pm-session, pm-lock, generation, issue-2942, pm-rename, owner, pm-mailbox
// #2942 S7: every PM write path (init, add, remove, inherit, set-sequence, set-reason, rename) runs under the PM lock,
// so a competing inherit or same-tag init waits and is refused; an old generation's write is refused.
// TL3 gap (what this test does NOT catch):
// - two real UserPromptSubmit hooks of two Claude Code sessions firing in the same second;
// - lock contention across state roots other than the pinned WORKFLOW_STATE_DIR.
const { test, after } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P } = X;
after(() => { restore(); });

let n = 0;
const sid = () => P.uuid(0x29420200 + (++n));
const tag = () => `PM-gen${++n}`;
const busy = (r) => typeof r.block === "string" && /pm-lock-busy/.test(r.block);
const seed = (o) => { const s = sid(); P.seedPm(s, P.pm(o)); return s; };
const noPm = (s) => !P.exists(s) || P.readPm(s) === undefined || P.readPm(s) === null;

// PATHS: each sets up its own PM and returns run() -> {refused, text} plus check() that nothing was written.
const PATHS = {
  init: () => { const s = sid(); const t = tag(); return { run: () => X.write(s, P.wrapped("pm-init", `${t} #9701 theme`), { pmField: X.field() }), check: () => assert.ok(noPm(s)) }; },
  add: () => { const s = seed({ tag: tag(), issues: [9711] }); const b = P.readPm(s); return { run: () => X.write(s, P.wrapped("pm-add", "#9712 reason"), { pmField: X.field() }), check: () => assert.deepStrictEqual(P.readPm(s), b) }; },
  remove: () => { const s = seed({ tag: tag(), issues: [9721, 9722] }); const b = P.readPm(s); return { run: () => X.write(s, P.wrapped("pm-remove", "#9722 reason"), { pmField: X.field() }), check: () => assert.deepStrictEqual(P.readPm(s), b) }; },
  inherit: () => { const up = seed({ tag: tag(), issues: [9731] }); const d = sid(); P.seedState(d); return { run: () => X.write(d, P.wrapped("resume-session", `--from ${up}`), { pmField: X.field() }), check: () => assert.ok(noPm(d)) }; },
  "set-sequence": () => { const s = seed({ tag: tag(), issues: [9741] }); const b = P.readPm(s); return { run: () => X.cli(["set-sequence", "--file", X.seqFile(X.table([9741]))], s), check: () => assert.deepStrictEqual(P.readPm(s), b) }; },
  "set-reason": () => { const s = seed({ tag: tag(), issues: [9751], assignment_log: X.unstatedLog([9751]) }); const b = P.readPm(s); return { run: () => X.cli(["set-reason", "--text", "late reason"], s), check: () => assert.deepStrictEqual(P.readPm(s), b) }; },
  rename: () => { const s = seed({ tag: tag(), issues: [9761] }); const b = P.readPm(s); return { run: () => X.write(s, P.wrapped("pm-rename", `PM-ren${n}`), { pmField: X.field() }), check: () => assert.deepStrictEqual(P.readPm(s), b) }; },
};
const textOf = (r) => `${r.block || ""}${r.err || ""}${r.threw || ""}`;
const refused = (r) => Boolean(r.block) || (r.code !== undefined && r.code !== 0);

caseBegin("every-pm-path-waits-for-the-lock", "hooks/pm-session/pm-lock.js");
for (const [name, mk] of Object.entries(PATHS)) {
  test(`L-${name}: a live holder makes ${name} wait about 1500 ms, then refuse with pm-lock-busy and write nothing`, () => {
    const p = mk();
    const h = X.holdLock();
    let r;
    try { r = p.run(); } finally { h.release(); }
    assert.ok(refused(r) && /pm-lock-busy/.test(textOf(r)), JSON.stringify(r));
    assert.ok(r.ms >= 1000 && r.ms < 6000, `waited ${r.ms} ms`);
    p.check();
  });
}
caseEnd();

caseBegin("writer-competitors-are-serialized", "hooks/pm-session/writer.js");
// The competitor runs in its own process while this one is inside the lock (during the PM field write).
function raced(competitor) {
  const f = X.field();
  let seen = null;
  const write = f.write;
  f.write = (ref, value) => { if (!seen) seen = competitor(); return write(ref, value); };
  return { f, seen: () => seen };
}
test("W1 init vs a same-tag init: the competitor is refused with pm-lock-busy; only the first holds the tag", () => {
  const a = sid(); const b = sid(); const t = tag();
  P.seedState(b);
  const race = raced(() => X.childWrite(b, P.wrapped("pm-init", `${t} #9801 theme`)));
  const r = X.write(a, P.wrapped("pm-init", `${t} #9802 theme`), { pmField: race.f });
  assert.ok(race.seen() && busy(race.seen()), JSON.stringify(race.seen()));
  assert.ok(!r.block && !r.threw, JSON.stringify(r));
  assert.strictEqual(P.readPm(a).tag, t);
  assert.ok(noPm(b), JSON.stringify(P.readPm(b)));
});
for (const [op, args, issues] of [["add", "#9812 reason", [9811]], ["remove", "#9822 reason", [9821, 9822]], ["rename", null, [9831]]]) {
  test(`W-${op}: an inherit of the same PM during /pm-${op} is refused with pm-lock-busy; /pm-${op} lands`, () => {
    const s = seed({ tag: tag(), issues });
    const d = sid();
    P.seedState(d);
    const race = raced(() => X.childWrite(d, P.wrapped("resume-session", `--from ${s}`)));
    const r = X.write(s, P.wrapped(`pm-${op}`, args || `PM-ren${n}`), { pmField: race.f });
    assert.ok(race.seen() && busy(race.seen()), JSON.stringify(race.seen()));
    assert.ok(!r.block && !r.threw, JSON.stringify(r));
    assert.ok(noPm(d), "the competing inherit wrote a generation");
  });
}
caseEnd();

caseBegin("inherit-competitors-are-serialized", "hooks/pm-session/inherit.js");
test("I1 two inherits from one upstream: the second waits and is refused; one current generation results", () => {
  const up = seed({ tag: tag(), issues: [9901], sequence: { updated_at: "2026-11-02T00:00:00.000Z", tables: X.table([9901]).tables } });
  const d1 = sid(); const d2 = sid();
  P.seedState(d1); P.seedState(d2);
  let seen = null;
  const fetchAncestorChains = (refs, o) => {
    if (!seen) seen = X.childWrite(d2, P.wrapped("resume-session", `--from ${up}`));
    return require("../../bin/lib/forge-issue-links").fetchAncestorChains(refs, o);
  };
  const r = X.write(d1, P.wrapped("resume-session", `--from ${up}`), { fetchAncestorChains });
  assert.ok(seen && busy(seen), JSON.stringify(seen));
  assert.ok(!r.block && !r.threw && P.readPm(d1), JSON.stringify(r));
  assert.ok(noPm(d2));
});
caseEnd();

caseBegin("old-generation-writes-are-refused", "bin/lib/pm-state/cli.js");
function generations(o) {
  const t = tag();
  const old = seed(Object.assign({ tag: t, current_since: "2026-11-01T00:00:00.000Z" }, o));
  const cur = seed(Object.assign({ tag: t, current_since: "2026-11-05T00:00:00.000Z" }, o));
  return { t, old, cur };
}
test("G1 set-sequence from an old generation exits non-zero with stale-generation", () => {
  const g = generations({ issues: [9951] });
  const b = P.readPm(g.old);
  const r = X.cli(["set-sequence", "--file", X.seqFile(X.table([9951]))], g.old);
  assert.notStrictEqual(r.code, 0, JSON.stringify(r));
  assert.match(r.err, /stale-generation/);
  assert.deepStrictEqual(P.readPm(g.old), b);
});
test("G2 set-reason from an old generation exits non-zero with stale-generation", () => {
  const g = generations({ issues: [9961], assignment_log: X.unstatedLog([9961]) });
  const b = P.readPm(g.old);
  const r = X.cli(["set-reason", "--text", "late reason"], g.old);
  assert.notStrictEqual(r.code, 0, JSON.stringify(r));
  assert.match(r.err, /stale-generation/);
  assert.deepStrictEqual(P.readPm(g.old), b);
});
test("G3 set-sequence from a competitor-free current generation still writes (no false refusal)", () => {
  const g = generations({ issues: [9971] });
  const r = X.cli(["set-sequence", "--file", X.seqFile(X.table([9971]))], g.cur);
  assert.strictEqual(r.code, 0, JSON.stringify(r));
});
test("G4 an inherit of the PM during set-sequence is refused with pm-lock-busy; the table lands", () => {
  const s = seed({ tag: tag(), issues: [9981] });
  const d = sid();
  P.seedState(d);
  let seen = null;
  const fetchAncestorChains = (refs, o) => {
    if (!seen) seen = X.childWrite(d, P.wrapped("resume-session", `--from ${s}`));
    return require("../../bin/lib/forge-issue-links").fetchAncestorChains(refs, o);
  };
  const r = X.cli(["set-sequence", "--file", X.seqFile(X.table([9981]))], s, { fetchAncestorChains });
  assert.ok(seen && busy(seen), JSON.stringify(seen));
  assert.strictEqual(r.code, 0, JSON.stringify(r));
  assert.ok(noPm(d));
});
caseEnd();

caseBegin("set-reason-vs-inherit-race", "bin/lib/pm-state/cli.js");
test("G5 an inherit of the PM during set-reason is refused with pm-lock-busy; the reason lands", () => {
  const s = seed({ tag: tag(), issues: [9985], assignment_log: X.unstatedLog([9985]) });
  const d = sid();
  P.seedState(d);
  // set-reason has no forge call to hook, so the competitor starts from the first PM scan made while pm.lock is held.
  const scanMod = P.load("hooks/pm-session/scan.js");
  const orig = scanMod.listPmFiles;
  let seen = null;
  scanMod.listPmFiles = (...a) => {
    if (!seen && require("node:fs").existsSync(X.lockPath())) seen = X.childWrite(d, P.wrapped("resume-session", `--from ${s}`));
    return orig.apply(scanMod, a);
  };
  let r;
  try { r = X.cli(["set-reason", "--text", "raced reason"], s); } finally { scanMod.listPmFiles = orig; }
  assert.ok(seen && busy(seen), JSON.stringify(seen));
  assert.strictEqual(r.code, 0, JSON.stringify(r));
  assert.strictEqual(P.readPm(s).assignment_log.slice(-1)[0].reason, "raced reason");
  assert.ok(noPm(d), "the competing inherit wrote a generation");
});
caseEnd();

caseBegin("old-generation-rename-is-refused", "hooks/pm-session/rename.js");
test("R1 /pm-rename from an old generation is refused, writes no PM field and leaves both generations as they were", () => {
  const g = generations({ issues: [9991] });
  const b = { old: P.readPm(g.old), cur: P.readPm(g.cur) };
  const f = X.field();
  const r = X.write(g.old, P.wrapped("pm-rename", `PM-ren${n}`), { pmField: f });
  assert.ok(typeof r.block === "string" && /generation/i.test(r.block), JSON.stringify(r));
  assert.strictEqual(f.writes.length, 0);
  assert.deepStrictEqual({ old: P.readPm(g.old), cur: P.readPm(g.cur) }, b);
});
caseEnd();

// #2942 S10: /pm-rename <new> checks the tag like /pm-init, records rename_pending, rewrites every issue's PM field,
// then swaps the tag, retires the old one and moves the old tag's mailbox, all under the PM lock.
// TL3 gap: a real Projects v2 board where some item-edit calls land after the writer's budget ran out;
// the session name shown by a live Claude Code session after the tag changes (title hook re-reads per prompt).
const fs = require("node:fs");
const path = require("node:path");
const { G } = X;
let rnN = 0;
const rnSid = () => P.uuid(0x29420500 + (++rnN));
const rnSeed = (o) => { const s = rnSid(); P.seedPm(s, P.pm(o)); return s; };
const box = (t) => path.join(process.env.WORKFLOW_STATE_DIR, "pm-mailbox", `${t}.jsonl`);
const rename = (s, arg, f) => X.write(s, P.wrapped("pm-rename", arg), { pmField: f });
const ok = (r) => !r.block && !r.threw;
// owned(tag, nums) -> a PM whose issues' fields already carry its tag (the board as /pm-init left it).
function owned(t, nums, extra) {
  const s = rnSeed(Object.assign({ tag: t, issues: nums }, extra || {}));
  const values = {};
  for (const k of nums) values[`o/r#${k}`] = t;
  G.setMap(Object.fromEntries(nums.map((k) => [`o/r#${k}`, { pm: t }])));
  return { s, f: X.field(values) };
}

caseBegin("rename-requirements", "hooks/pm-session/rename.js");
test("RN1 an accepted rename rewrites every issue's field, swaps the tag and retires the old one", () => {
  const { s, f } = owned("PM-rn1", [10301, 10302, 10303], { assignment_log: X.unstatedLog([10301, 10302, 10303]) });
  const before = P.readPm(s);
  const r = rename(s, "PM-rn1-new", f);
  assert.ok(ok(r), JSON.stringify(r));
  assert.deepStrictEqual(f.writes.map((w) => w.ref).sort(), ["o/r#10301", "o/r#10302", "o/r#10303"]);
  assert.ok(f.writes.every((w) => w.value === "PM-rn1-new"), JSON.stringify(f.writes));
  const pm = P.readPm(s);
  assert.strictEqual(pm.tag, "PM-rn1-new");
  assert.deepStrictEqual(pm.retired_tags, ["PM-rn1"]);
  assert.strictEqual(pm.rename_pending, undefined, "the pending record must be cleared at the end");
  for (const k of ["issues", "sequence", "assignment_log", "current_since"]) assert.deepStrictEqual(pm[k], before[k], `${k} must carry over`);
});
test("RN2 a malformed new tag is refused like /pm-init; nothing is written", () => {
  const { s, f } = owned("PM-rn2", [10311]);
  const before = P.readPm(s);
  const r = rename(s, "PM_bad!tag", f);
  assert.ok(typeof r.block === "string" && r.block.length > 0, JSON.stringify(r));
  assert.strictEqual(f.writes.length, 0);
  assert.deepStrictEqual(P.readPm(s), before);
});
for (const [name, mk] of [
  ["an active PM's tag", () => rnSeed({ tag: "PM-rn3-busy", issues: [] }) && "PM-rn3-busy"],
  ["an ended PM's tag", () => rnSeed({ tag: "PM-rn3-ended", issues: [], archived_at: "2026-11-10T00:00:00.000Z" }) && "PM-rn3-ended"],
  ["another PM's retired tag", () => { const o = rnSeed({ tag: "PM-rn3-now", issues: [] }); const st = P.raw(o); st.pm.retired_tags = ["PM-rn3-was"]; P.writeRaw(o, st); return "PM-rn3-was"; }],
]) {
  test(`RN3 renaming to ${name} is refused as already used; nothing is written`, () => {
    const taken = mk();
    const { s, f } = owned(`PM-rn3-${++rnN}`, [10321]);
    const before = P.readPm(s);
    const r = rename(s, taken, f);
    assert.ok(typeof r.block === "string" && r.block.includes(taken), JSON.stringify(r));
    assert.strictEqual(f.writes.length, 0);
    assert.deepStrictEqual(P.readPm(s), before);
  });
}
test("RN4 after a rename the old tag can never be taken again by /pm-init", () => {
  const { s, f } = owned("PM-rn4", [10331]);
  assert.ok(ok(rename(s, "PM-rn4-new", f)));
  assert.strictEqual(P.readPm(s).tag, "PM-rn4-new", "the rename itself did not land");
  const other = rnSid();
  P.seedState(other);
  const r = X.write(other, P.wrapped("pm-init", "PM-rn4 #10339 theme"), { pmField: X.field() });
  assert.ok(typeof r.block === "string" && r.block.includes("PM-rn4"), JSON.stringify(r));
  assert.ok(!P.readPm(other));
});
test("RN5 /pm-rename mid-sentence (not the leading command) renames nothing", () => {
  const { s, f } = owned("PM-rn5", [10341]);
  const before = P.readPm(s);
  X.write(s, "please run /pm-rename PM-rn5-new later", { pmField: f });
  assert.strictEqual(f.writes.length, 0);
  assert.deepStrictEqual(P.readPm(s), before);
});
caseEnd();

caseBegin("rename-failure-and-resume", "hooks/pm-session/rename.js");
// failing(f, k) -> the field fails the k-th write (1-based) and only that one.
function failing(f, k) {
  const write = f.write;
  let i = 0;
  f.write = (ref, value) => (++i === k ? { result: "failed" } : write(ref, value));
  return f;
}
test("RF1 a field write failing midway keeps rename_pending and the old tag, and shows the reason", () => {
  const { s, f } = owned("PM-rf1", [10401, 10402, 10403]);
  const r = rename(s, "PM-rf1-new", failing(f, 2));
  assert.ok(typeof r.block === "string" && /pm-field/i.test(r.block), JSON.stringify(r));
  const pm = P.readPm(s);
  assert.strictEqual(pm.tag, "PM-rf1");
  assert.deepStrictEqual(pm.rename_pending, { from: "PM-rf1", to: "PM-rf1-new" });
});
test("RF2 retyping the same /pm-rename skips the issues already carrying the new tag and finishes", () => {
  const { s, f } = owned("PM-rf2", [10411, 10412, 10413]);
  rename(s, "PM-rf2-new", failing(f, 2));
  const done = f.writes.filter((w) => w.value === "PM-rf2-new").map((w) => w.ref);
  assert.ok(done.length >= 1, `the first run wrote nothing: ${JSON.stringify(f.writes)}`);
  const again = X.field(f.values);
  const r = rename(s, "PM-rf2-new", again);
  assert.ok(ok(r), JSON.stringify(r));
  for (const ref of done) assert.ok(!again.writes.some((w) => w.ref === ref), `${ref} was rewritten: ${JSON.stringify(again.writes)}`);
  assert.ok(["o/r#10411", "o/r#10412", "o/r#10413"].every((k) => again.values[k] === "PM-rf2-new"), JSON.stringify(again.values));
  const pm = P.readPm(s);
  assert.strictEqual(pm.tag, "PM-rf2-new");
  assert.strictEqual(pm.rename_pending, undefined);
  assert.deepStrictEqual(pm.retired_tags, ["PM-rf2"]);
});
test("RF3 while rename_pending exists, a rename to a different tag is refused and writes nothing", () => {
  const { s, f } = owned("PM-rf3", [10421, 10422]);
  rename(s, "PM-rf3-new", failing(f, 2));
  const before = P.readPm(s);
  const other = X.field(f.values);
  const r = rename(s, "PM-rf3-other", other);
  assert.ok(typeof r.block === "string" && r.block.includes("PM-rf3-new"), JSON.stringify(r));
  assert.strictEqual(other.writes.length, 0);
  assert.deepStrictEqual(P.readPm(s), before);
});
caseEnd();

caseBegin("rename-moves-the-mailbox", "hooks/pm-session/rename.js");
test("RM1 the old tag's mailbox moves to the new tag once, in the same command", () => {
  const { s, f } = owned("PM-rm1", [10501]);
  const lines = [{ id: "n-rm1-a", point: "start", issue: "o/r#10501" }, { id: "n-rm1-b", point: "merge", issue: "o/r#10501" }];
  fs.mkdirSync(path.dirname(box("PM-rm1")), { recursive: true });
  fs.writeFileSync(box("PM-rm1"), lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  assert.ok(ok(rename(s, "PM-rm1-new", f)));
  assert.ok(fs.existsSync(box("PM-rm1-new")), "the new tag's mailbox is missing");
  const moved = fs.readFileSync(box("PM-rm1-new"), "utf8").trim().split("\n").map((l) => JSON.parse(l).id);
  assert.deepStrictEqual(moved.sort(), ["n-rm1-a", "n-rm1-b"]);
  const left = fs.existsSync(box("PM-rm1")) ? fs.readFileSync(box("PM-rm1"), "utf8").trim() : "";
  assert.strictEqual(left, "", "the old tag's mailbox must be empty after the move");
});
caseEnd();

caseBegin("rename-writes-fields-before-the-tag-switch", "hooks/pm-session/rename.js");
// spying(f, s) -> before each field write, records the PM state as it is on disk at that moment (f.seen).
function spying(f, s) {
  const write = f.write;
  f.seen = [];
  f.write = (ref, value) => { f.seen.push(P.readPm(s)); return write(ref, value); };
  return f;
}
const PENDING_SEEN = (seen, from, to) => seen.forEach((pm, i) => {
  assert.strictEqual(pm.tag, from, `field write ${i + 1} saw the tag already switched`);
  assert.deepStrictEqual(pm.rename_pending, { from, to }, `field write ${i + 1} ran without rename_pending on disk`);
  assert.ok(!(pm.retired_tags || []).includes(from), `field write ${i + 1} saw the old tag already retired`);
});
test("RO1 rename_pending is on disk before the first field write; every write sees the old tag; the switch follows the last write", () => {
  const { s, f } = owned("PM-ro1", [10601, 10602, 10603]);
  const r = rename(s, "PM-ro1-new", spying(f, s));
  assert.ok(ok(r), JSON.stringify(r));
  assert.deepStrictEqual(f.writes.map((w) => w.ref).sort(), ["o/r#10601", "o/r#10602", "o/r#10603"]);
  assert.strictEqual(f.seen.length, 3, `expected one snapshot per field write: ${JSON.stringify(f.seen)}`);
  PENDING_SEEN(f.seen, "PM-ro1", "PM-ro1-new");
  const pm = P.readPm(s);
  assert.strictEqual(pm.tag, "PM-ro1-new");
  assert.deepStrictEqual(pm.retired_tags, ["PM-ro1"]);
  assert.strictEqual(pm.rename_pending, undefined);
});
test("RO2 the last field write failing leaves the tag unswitched and the old tag unretired", () => {
  const { s, f } = owned("PM-ro2", [10611, 10612, 10613]);
  const r = rename(s, "PM-ro2-new", spying(failing(f, 3), s));
  assert.ok(typeof r.block === "string" && r.block.length > 0, JSON.stringify(r));
  assert.strictEqual(f.seen.length, 3, `the rename stopped before the last write: ${JSON.stringify(f.seen)}`);
  PENDING_SEEN(f.seen, "PM-ro2", "PM-ro2-new");
  const pm = P.readPm(s);
  assert.strictEqual(pm.tag, "PM-ro2");
  assert.ok(!(pm.retired_tags || []).includes("PM-ro2"), JSON.stringify(pm));
  assert.deepStrictEqual(pm.rename_pending, { from: "PM-ro2", to: "PM-ro2-new" });
});
caseEnd();

caseBegin("mid-rename-owner-resolves-both-tags", "bin/lib/pm-state/owner.js");
test("RO3 after a rename stopped midway, owner maps an issue still on the old tag and one on the new tag to the same generation", () => {
  const { s, f } = owned("PM-ro3", [10621, 10622, 10623]);
  const r = rename(s, "PM-ro3-new", failing(f, 2));
  assert.ok(typeof r.block === "string", JSON.stringify(r));
  assert.deepStrictEqual(P.readPm(s).rename_pending, { from: "PM-ro3", to: "PM-ro3-new" }, "the rename did not stop midway");
  const refWith = (v) => Object.keys(f.values).find((k) => f.values[k] === v);
  const oldRef = refWith("PM-ro3");
  const newRef = refWith("PM-ro3-new");
  assert.ok(oldRef && newRef, `expected one field on each tag: ${JSON.stringify(f.values)}`);
  G.setMap(Object.fromEntries(Object.entries(f.values).map(([k, v]) => [k, { pm: v }])));
  const ask = (ref) => X.cli(["owner", "--issue", `#${ref.split("#")[1]}`], undefined);
  const a = ask(oldRef);
  const b = ask(newRef);
  assert.strictEqual(a.code, 0, JSON.stringify(a));
  assert.strictEqual(b.code, 0, JSON.stringify(b));
  assert.deepStrictEqual(a.json, b.json);
  assert.strictEqual(a.json.session_id, s);
  assert.ok(["PM-ro3", "PM-ro3-new"].includes(a.json.tag), JSON.stringify(a.json));
});
caseEnd();

caseBegin("rename-mailbox-move-is-idempotent", "bin/lib/pm-notify/mailbox.js");
const ids = (t) => X.readBox(t).map((e) => e.id).sort();
const note = (id, k) => ({ id, point: "start", issue: `o/r#${k}` });
test("RM2 the new tag's mailbox already holding notifications: after the move each id is there exactly once", () => {
  const { s, f } = owned("PM-rm2", [10701]);
  X.writeBox("PM-rm2", [note("n-rm2-a", 10701), note("n-rm2-b", 10701)]);
  X.writeBox("PM-rm2-new", [note("n-rm2-b", 10701), note("n-rm2-c", 10701)]);
  assert.ok(ok(rename(s, "PM-rm2-new", f)));
  assert.deepStrictEqual(ids("PM-rm2-new"), ["n-rm2-a", "n-rm2-b", "n-rm2-c"]);
  assert.deepStrictEqual(ids("PM-rm2"), [], "the old tag's mailbox must be empty or removed");
});
test("RM3 retyping /pm-rename after a midway field failure moves each notification exactly once", () => {
  const { s, f } = owned("PM-rm3", [10711, 10712]);
  X.writeBox("PM-rm3", [note("n-rm3-a", 10711), note("n-rm3-b", 10712)]);
  const first = rename(s, "PM-rm3-new", failing(f, 2));
  assert.ok(typeof first.block === "string", JSON.stringify(first));
  assert.deepStrictEqual([...new Set(ids("PM-rm3").concat(ids("PM-rm3-new")))].sort(), ["n-rm3-a", "n-rm3-b"], "the failed run lost a notification");
  assert.ok(ok(rename(s, "PM-rm3-new", X.field(f.values))));
  assert.deepStrictEqual(ids("PM-rm3-new"), ["n-rm3-a", "n-rm3-b"]);
  assert.deepStrictEqual(ids("PM-rm3"), []);
});
test("RM4 a move interrupted after copying (both mailboxes hold an id) is finished by the retry without a duplicate", () => {
  const { s } = owned("PM-rm4", [10721]);
  const st = P.raw(s);
  st.pm.rename_pending = { from: "PM-rm4", to: "PM-rm4-new" };
  P.writeRaw(s, st);
  G.setMap({ "o/r#10721": { pm: "PM-rm4-new" } });
  X.writeBox("PM-rm4", [note("n-rm4-a", 10721), note("n-rm4-b", 10721)]);
  X.writeBox("PM-rm4-new", [note("n-rm4-a", 10721)]);
  assert.ok(ok(rename(s, "PM-rm4-new", X.field({ "o/r#10721": "PM-rm4-new" }))));
  assert.deepStrictEqual(ids("PM-rm4-new"), ["n-rm4-a", "n-rm4-b"]);
  assert.deepStrictEqual(ids("PM-rm4"), []);
  assert.strictEqual(P.readPm(s).tag, "PM-rm4-new");
});
caseEnd();

caseBegin("rename-third-pm-field-and-failed-move", "hooks/pm-session/rename.js");
test("RT1 a field naming a third PM (moved in the Project UI) is left alone; the old-tag and empty fields are rewritten", () => {
  const { s, f } = owned("PM-rt1", [10801, 10802, 10803]);
  f.values["o/r#10802"] = "PM-rt1-third";
  f.values["o/r#10803"] = null;
  assert.ok(ok(rename(s, "PM-rt1-new", f)));
  assert.deepStrictEqual(f.writes.map((w) => w.ref).sort(), ["o/r#10801", "o/r#10803"]);
  assert.strictEqual(f.values["o/r#10802"], "PM-rt1-third");
});
test("RT2 a failed mailbox move keeps rename_pending and the old tag; the same /pm-rename resumes and finishes", () => {
  const { s, f } = owned("PM-rt2", [10811]);
  X.writeBox("PM-rt2", [note("n-rt2", 10811)]);
  const mb = P.load("bin/lib/pm-notify/mailbox.js");
  const orig = mb.moveMailbox;
  mb.moveMailbox = () => { throw new Error("EBUSY mailbox"); };
  let first;
  try { first = rename(s, "PM-rt2-new", f); } finally { mb.moveMailbox = orig; }
  assert.ok(!ok(first), JSON.stringify(first));
  assert.strictEqual(P.readPm(s).tag, "PM-rt2");
  assert.deepStrictEqual(P.readPm(s).rename_pending, { from: "PM-rt2", to: "PM-rt2-new" });
  assert.ok(ok(rename(s, "PM-rt2-new", X.field(f.values))));
  assert.strictEqual(P.readPm(s).tag, "PM-rt2-new");
  assert.deepStrictEqual(ids("PM-rt2-new"), ["n-rt2"]);
  assert.deepStrictEqual(ids("PM-rt2"), []);
});
const unreadable = (f) => { f.read = () => ({ ok: false, reason: "forge down" }); return f; };
test("RT3 an unreadable PM field refuses the rename: no field write, mailbox unmoved, rename_pending kept, tag unchanged", () => {
  const { s, f } = owned("PM-rt3", [10821, 10822]);
  X.writeBox("PM-rt3", [note("n-rt3", 10821)]);
  const r = rename(s, "PM-rt3-new", unreadable(f));
  assert.ok(typeof r.block === "string" && /cannot be read/.test(r.block) && /the same \/pm-rename resumes the rename/.test(r.block), JSON.stringify(r));
  assert.strictEqual(f.writes.length, 0, JSON.stringify(f.writes));
  assert.deepStrictEqual(ids("PM-rt3"), ["n-rt3"]);
  assert.deepStrictEqual(ids("PM-rt3-new"), []);
  const pm = P.readPm(s);
  assert.strictEqual(pm.tag, "PM-rt3");
  assert.deepStrictEqual(pm.rename_pending, { from: "PM-rt3", to: "PM-rt3-new" });
  assert.ok(!(pm.retired_tags || []).includes("PM-rt3"), JSON.stringify(pm));
});
test("RT4 after an unreadable-field refusal, the same /pm-rename with a working read finishes and writes only own/empty fields", () => {
  const { s, f } = owned("PM-rt4", [10831, 10832, 10833]);
  X.writeBox("PM-rt4", [note("n-rt4", 10831)]);
  assert.ok(!ok(rename(s, "PM-rt4-new", unreadable(f))));
  const again = X.field(Object.assign({}, f.values, { "o/r#10832": "PM-rt4-third", "o/r#10833": null }));
  assert.ok(ok(rename(s, "PM-rt4-new", again)));
  assert.deepStrictEqual(again.writes.map((w) => w.ref).sort(), ["o/r#10831", "o/r#10833"]);
  assert.ok(again.writes.every((w) => w.value === "PM-rt4-new"), JSON.stringify(again.writes));
  assert.strictEqual(again.values["o/r#10832"], "PM-rt4-third");
  const pm = P.readPm(s);
  assert.strictEqual(pm.tag, "PM-rt4-new");
  assert.strictEqual(pm.rename_pending, undefined);
  assert.deepStrictEqual(pm.retired_tags, ["PM-rt4"]);
  assert.deepStrictEqual(ids("PM-rt4-new"), ["n-rt4"]);
});
caseEnd();
