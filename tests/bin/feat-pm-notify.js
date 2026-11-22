"use strict";
// Tests: bin/lib/pm-notify/record.js, bin/lib/pm-notify/next.js, bin/lib/pm-notify/settle.js, bin/lib/pm-notify/mailbox.js, bin/lib/pm-notify/close.js, bin/lib/pm-notify/inbox.js, hooks/session-start.js, skills/session-close/SKILL.md
// Tags: TL2, scope:common, pm-session, pm-notify, issue-2942
// #2942 S12-S15: the notification-point layer. record keeps a pending notification in the workflow state, next
// re-resolves its owner, settle files a timeout/offline into the tag's mailbox, close moves the undecidable ones
// to unassigned.jsonl, and inbox --pm shows and empties the PM's mailbox after every PM command and at start.
// TL3 gap (what this test does NOT catch):
// - a real SendMessage ack arriving after the 60 s timer (the PM's id dedupe is checked on the mailbox only);
// - the skill-side loop (pm-notify.md) that an agent walks: next -> find-peer -> SendMessage -> settle.
const { test, after } = require("node:test");
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
after(() => { restore(); });

let n = 0;
const sid = () => P.uuid(0x29420700 + (++n));
const seed = (o) => { const s = sid(); P.seedPm(s, P.pm(o)); return s; };
const wf = () => { const s = sid(); P.seedState(s); return s; };
const brief = (r) => JSON.stringify({ code: r.code, out: r.out, err: r.err });
// recorded(s, point, issue) -> the id of a freshly recorded notification (record prints ID=<id>).
function recorded(s, point, issue) {
  const r = X.notify(["record", "--point", point, "--issue", issue], { sid: s });
  assert.strictEqual(r.code, 0, brief(r));
  assert.ok(r.kv.ID, `record printed no ID=: ${brief(r)}`);
  return r.kv.ID;
}
const noteOf = (s, id) => X.notes(s).find((e) => e.id === id);
const gone = (s, id) => { const e = noteOf(s, id); return !e || e.result === "dropped"; };
const next = (s) => X.notify(["next"], { sid: s });
const settle = (s, id, result) => X.notify(["settle", "--id", id, "--result", result], { sid: s });
const ids = (name) => X.readBox(name).map((e) => e.id);

caseBegin("record-and-next", "bin/lib/pm-notify/record.js");
test("N1 record keeps a pending notification (id, point, issue, time) in the workflow state", () => {
  const s = wf();
  const id = recorded(s, "start", "#10701");
  const e = noteOf(s, id);
  assert.ok(e, JSON.stringify(X.notes(s)));
  assert.strictEqual(e.point, "start");
  assert.match(String(e.issue), /#10701$/);
  assert.ok(e.at, "the record has no time");
});
test("N2 next resolves the owner and prints a SEND line with the PM's tag and session", () => {
  const pm = seed({ tag: "PM-nt2", issues: [10711] });
  G.setMap({ "o/r#10711": { pm: "PM-nt2" } });
  const s = wf();
  const id = recorded(s, "start", "#10711");
  const r = next(s);
  assert.strictEqual(r.code, 0, brief(r));
  assert.match(r.out, /SEND/, brief(r));
  assert.strictEqual(r.kv.ID, id, brief(r));
  assert.strictEqual(r.kv.TAG, "PM-nt2", brief(r));
  assert.strictEqual(r.kv.SESSION, pm, brief(r));
});
test("N3 no owner any more ({pm:null}) -> the notification is dropped, nothing is sent", () => {
  G.setMap({ "o/r#10721": {} });
  const s = wf();
  const id = recorded(s, "start", "#10721");
  const r = next(s);
  assert.doesNotMatch(r.out, /SEND/, brief(r));
  assert.ok(gone(s, id), JSON.stringify(X.notes(s)));
});
test("N4 an undecidable owner is kept as undelivered with its reason, never treated as no PM", () => {
  G.setMap({ "o/r#10731": { pm: "PM-not-here" } });
  const s = wf();
  const id = recorded(s, "start", "#10731");
  const r = next(s);
  assert.doesNotMatch(r.out, /SEND/, brief(r));
  const e = noteOf(s, id);
  assert.ok(e && e.result === "undelivered", JSON.stringify(X.notes(s)));
  assert.match(JSON.stringify(e), /tag-not-local/);
});
test("N5 the owner changed since the first try -> the resend goes to the new owner", () => {
  G.setMap({ "o/r#10741": { pm: "PM-not-yet" } });
  const s = wf();
  const id = recorded(s, "start", "#10741");
  next(s);
  const pm = seed({ tag: "PM-nt5", issues: [10741] });
  G.setMap({ "o/r#10741": { pm: "PM-nt5" } });
  const r = next(s);
  assert.strictEqual(r.kv.ID, id, brief(r));
  assert.strictEqual(r.kv.TAG, "PM-nt5", brief(r));
  assert.strictEqual(r.kv.SESSION, pm, brief(r));
});
test("N6 a notification tied to a forge state that no longer holds (reopen of a closed issue) is dropped", () => {
  seed({ tag: "PM-nt6", issues: [10751] });
  G.setMap({ "o/r#10751": { pm: "PM-nt6", state: "CLOSED" } });
  const s = wf();
  const id = recorded(s, "reopen", "#10751");
  const r = next(s);
  assert.doesNotMatch(r.out, /SEND/, brief(r));
  assert.ok(gone(s, id), JSON.stringify(X.notes(s)));
});
caseEnd();

caseBegin("settle-and-mailbox", "bin/lib/pm-notify/settle.js");
// sent(tag, num) -> {s, id}: a notification next has just handed out for sending to tag's PM.
function sent(tag, num) {
  G.setMap({ [`o/r#${num}`]: { pm: tag } });
  const s = wf();
  const id = recorded(s, "start", `#${num}`);
  assert.strictEqual(next(s).kv.ID, id);
  return { s, id };
}
test("S1 settle ack records the delivery; the mailbox stays empty", () => {
  seed({ tag: "PM-st1", issues: [10801] });
  const { s, id } = sent("PM-st1", 10801);
  assert.strictEqual(settle(s, id, "ack").code, 0);
  assert.strictEqual(noteOf(s, id).result, "ack");
  assert.deepStrictEqual(ids("PM-st1"), []);
});
for (const result of ["timeout", "offline"]) {
  test(`S2 settle ${result} files the notification into the tag's mailbox`, () => {
    const tag = `PM-st2-${result}`;
    seed({ tag, issues: [10811] });
    const { s, id } = sent(tag, 10811);
    assert.strictEqual(settle(s, id, result).code, 0);
    assert.strictEqual(noteOf(s, id).result, "mailbox");
    assert.deepStrictEqual(ids(tag), [id]);
  });
}
test("S3 the mailbox drops a duplicate id", () => {
  seed({ tag: "PM-st3", issues: [10821] });
  const { s, id } = sent("PM-st3", 10821);
  settle(s, id, "timeout");
  settle(s, id, "timeout");
  assert.deepStrictEqual(ids("PM-st3"), [id]);
});
test("S4 a write addressed to a tag retired by /pm-rename re-resolves owner and lands in the new tag's mailbox", () => {
  const pm = seed({ tag: "PM-st4-old", issues: [10831] });
  const { s, id } = sent("PM-st4-old", 10831);
  const st = P.raw(pm);
  st.pm.tag = "PM-st4-new";
  st.pm.retired_tags = ["PM-st4-old"];
  P.writeRaw(pm, st);
  G.setMap({ "o/r#10831": { pm: "PM-st4-new" } });
  settle(s, id, "timeout");
  assert.deepStrictEqual(ids("PM-st4-new"), [id]);
  assert.deepStrictEqual(ids("PM-st4-old"), []);
});
caseEnd();

caseBegin("close-moves-the-undecidable", "bin/lib/pm-notify/close.js");
test("C1 close moves a still-undecidable notification to unassigned.jsonl with its issue and reason, and lists it", () => {
  G.setMap({ "o/r#10901": { pm: "PM-unknown-c1" } });
  const s = wf();
  const id = recorded(s, "session-close", "#10901");
  const r = X.notify(["close"], { sid: s });
  assert.strictEqual(r.code, 0, brief(r));
  const moved = X.readBox("unassigned").find((e) => e.id === id);
  assert.ok(moved, JSON.stringify(X.readBox("unassigned")));
  assert.match(String(moved.issue), /#10901$/);
  assert.match(JSON.stringify(moved), /tag-not-local/);
  assert.match(r.out, /10901/, brief(r));
});
test("C2 session-close records its own notification (SC-6a), sends it through pm-notify.md, then runs close", () => {
  const text = fs.readFileSync(path.join(P.ROOT, "skills", "session-close", "SKILL.md"), "utf8");
  const at = (re) => { const m = re.exec(text); return m ? m.index : -1; };
  const sc6a = at(/SC-6a/);
  const rec = at(/pm-notify record --point session-close/);
  const send = at(/pm-notify\.md/);
  const close = at(/pm-notify close/);
  assert.ok(sc6a >= 0 && rec > sc6a && send > rec && close > send, JSON.stringify({ sc6a, rec, send, close }));
});
caseEnd();

caseBegin("inbox-shows-and-empties", "bin/lib/pm-notify/inbox.js");
const inbox = (pm) => X.notify(["inbox", "--pm"], { sid: pm });
test("I1 inbox --pm shows the own mailbox, empties it and remembers the ids in seen_notifications", () => {
  const pm = seed({ tag: "PM-ib1", issues: [11001] });
  X.writeBox("PM-ib1", [{ id: "n-ib1", point: "start", issue: "o/r#11001", from_session: "sess-ib1", at: "2026-11-20T00:00:00.000Z" }]);
  const r = inbox(pm);
  assert.strictEqual(r.code, 0, brief(r));
  assert.match(r.out, /sess-ib1/, brief(r));
  assert.deepStrictEqual(ids("PM-ib1"), []);
  assert.ok((P.readPm(pm).seen_notifications || []).includes("n-ib1"), JSON.stringify(P.readPm(pm)));
});
test("I2 inbox drops an id already in seen_notifications (a late SendMessage duplicate)", () => {
  const pm = seed({ tag: "PM-ib2", issues: [11011] });
  const st = P.raw(pm);
  st.pm.seen_notifications = ["n-ib2-old"];
  P.writeRaw(pm, st);
  X.writeBox("PM-ib2", [{ id: "n-ib2-old", point: "start", issue: "o/r#11011", from_session: "sess-ib2-old" }, { id: "n-ib2-new", point: "merge", issue: "o/r#11012", from_session: "sess-ib2-new" }]);
  const r = inbox(pm);
  assert.match(r.out, /sess-ib2-new/, brief(r));
  assert.doesNotMatch(r.out, /sess-ib2-old/, brief(r));
});
test("I3 inbox takes its own entries from unassigned.jsonl, drops the ownerless ones and leaves the rest", () => {
  const pm = seed({ tag: "PM-ib3", issues: [11021] });
  G.setMap({ "o/r#11021": { pm: "PM-ib3" }, "o/r#11022": {}, "o/r#11023": { pm: "PM-still-unknown" } });
  X.writeBox("unassigned", [
    { id: "u-mine", point: "start", issue: "o/r#11021", reason: "tag-not-local" },
    { id: "u-none", point: "start", issue: "o/r#11022", reason: "tag-not-local" },
    { id: "u-left", point: "start", issue: "o/r#11023", reason: "tag-not-local" },
  ]);
  const r = inbox(pm);
  assert.match(r.out, /11021/, brief(r));
  assert.deepStrictEqual(ids("unassigned"), ["u-left"]);
});
test("I4 bin/pm-state set-sequence runs inbox after the write", () => {
  const pm = seed({ tag: "PM-ib4", issues: [11031] });
  X.writeBox("PM-ib4", [{ id: "n-ib4", point: "start", issue: "o/r#11031", from_session: "sess-ib4" }]);
  const r = X.cli(["set-sequence", "--file", X.seqFile(X.table([11031]))], pm);
  assert.strictEqual(r.code, 0, JSON.stringify(r));
  assert.match(r.out + r.err, /sess-ib4/, JSON.stringify(r));
  assert.deepStrictEqual(ids("PM-ib4"), []);
});
test("I5 bin/pm-state set-reason runs inbox after the write", () => {
  const pm = seed({ tag: "PM-ib5", issues: [11041], assignment_log: X.unstatedLog([11041]) });
  X.writeBox("PM-ib5", [{ id: "n-ib5", point: "start", issue: "o/r#11041" }]);
  const r = X.cli(["set-reason", "--text", "late reason"], pm);
  assert.strictEqual(r.code, 0, JSON.stringify(r));
  assert.deepStrictEqual(ids("PM-ib5"), []);
});
test("I6 a PM command through the writer (/pm-add) runs inbox after the lock is released", () => {
  const pm = seed({ tag: "PM-ib6", issues: [11051] });
  G.setMap({ "o/r#11052": {} });
  X.writeBox("PM-ib6", [{ id: "n-ib6", point: "start", issue: "o/r#11051", from_session: "sess-ib6" }]);
  const r = X.write(pm, P.wrapped("pm-add", "#11052 reason"), { pmField: X.field() });
  assert.ok(!r.block && !r.threw, JSON.stringify(r));
  assert.match(String(r.context || ""), /sess-ib6/, JSON.stringify(r));
  assert.deepStrictEqual(ids("PM-ib6"), []);
});
test("I7 SessionStart of a PM session (compact/resume) runs inbox and puts it in additionalContext", () => {
  const pm = seed({ tag: "PM-ib7", issues: [11061] });
  X.writeBox("PM-ib7", [{ id: "n-ib7", point: "merge", issue: "o/r#11061", from_session: "sess-ib7" }]);
  // session-start.js also repairs ~/.claude/shell-snapshots and reads transcripts: pin a temp HOME and an empty transcript base.
  const home = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "pm-notify-i7-"));
  after(() => fs.rmSync(home, { recursive: true, force: true }));
  fs.mkdirSync(path.join(home, "transcripts"));
  const env = Object.assign({}, process.env, { HOME: home, USERPROFILE: home, CLAUDE_TRANSCRIPT_BASE_DIR: path.join(home, "transcripts") });
  delete env.CLAUDE_CODE_SESSION_ID;
  const input = JSON.stringify({ session_id: pm, hook_event_name: "SessionStart", source: "compact", cwd: X.F.home });
  const r = cp.spawnSync(process.execPath, [path.join(P.ROOT, "hooks", "session-start.js")], { input, cwd: X.F.home, env, encoding: "utf8", timeout: 60000 });
  let ctx = "";
  try { ctx = JSON.parse(String(r.stdout).trim().split("\n").pop()).additionalContext || ""; } catch (_) { ctx = ""; }
  assert.match(ctx, /sess-ib7/, `${r.stdout}${r.stderr}`);
  assert.deepStrictEqual(ids("PM-ib7"), []);
});
test("I8 a failing seen_notifications save leaves the mailbox as it was; the next inbox shows it", () => {
  const pm = seed({ tag: "PM-ib8", issues: [] });
  X.writeBox("PM-ib8", [{ id: "n-ib8", point: "start", issue: "o/r#11071", from_session: "sess-ib8" }]);
  const io = P.load("bin/lib/pm-notify/common.js").io;
  const orig = io.updateTopLevel;
  io.updateTopLevel = () => { throw new Error("disk full"); };
  let text;
  try { text = P.load("bin/lib/pm-notify/inbox.js").runInbox(pm); } finally { io.updateTopLevel = orig; }
  assert.match(text, /skipped/, text);
  assert.deepStrictEqual(ids("PM-ib8"), ["n-ib8"], "the mailbox was emptied before the seen ids were saved");
  assert.match(inbox(pm).out, /sess-ib8/);
  assert.deepStrictEqual(ids("PM-ib8"), []);
});
caseEnd();

caseBegin("next-retries-sending-and-keeps-unreadable", "bin/lib/pm-notify/next.js");
// putNote(s, note) -> s's workflow state with one notification written as is.
const putNote = (s, note) => { const st = P.raw(s); st.pm_notifications = [note]; P.writeRaw(s, st); };
test("N7 a note left sending (never settled) is handed out again by next", () => {
  const pm = seed({ tag: "PM-nt7", issues: [10761] });
  G.setMap({ "o/r#10761": { pm: "PM-nt7" } });
  const s = wf();
  const id = recorded(s, "start", "#10761");
  assert.strictEqual(next(s).kv.ID, id);
  assert.strictEqual(noteOf(s, id).result, "sending");
  const again = next(s);
  assert.strictEqual(again.kv.ID, id, brief(again));
  assert.strictEqual(again.kv.SESSION, pm, brief(again));
});
test("N8 a note whose issue cannot be read stays undelivered (issue-unreadable) and close moves it to unassigned", () => {
  const s = wf();
  putNote(s, { id: "n-nt8", point: "start", issue: "not-a-ref", from_session: s, result: "pending" });
  const r = next(s);
  assert.doesNotMatch(r.out, /SEND/, brief(r));
  assert.deepStrictEqual([noteOf(s, "n-nt8").result, noteOf(s, "n-nt8").reason], ["undelivered", "issue-unreadable"]);
  assert.strictEqual(X.notify(["close"], { sid: s }).code, 0);
  assert.ok(X.readBox("unassigned").some((e) => e.id === "n-nt8" && e.reason === "issue-unreadable"), JSON.stringify(X.readBox("unassigned")));
});
caseEnd();

caseBegin("close-resync-forge-state-and-rename", "bin/lib/pm-notify/close.js");
test("C3 close drops a reopen note whose issue is closed again (forge state re-read), filing it nowhere", () => {
  seed({ tag: "PM-cl3", issues: [10911] });
  G.setMap({ "o/r#10911": { pm: "PM-cl3", state: "OPEN" } });
  const s = wf();
  const id = recorded(s, "reopen", "#10911");
  assert.strictEqual(next(s).kv.ID, id);
  G.setMap({ "o/r#10911": { pm: "PM-cl3", state: "CLOSED" } });
  assert.strictEqual(X.notify(["close"], { sid: s }).code, 0);
  assert.strictEqual(noteOf(s, id).result, "dropped", JSON.stringify(X.notes(s)));
  assert.deepStrictEqual(ids("PM-cl3"), []);
  assert.ok(!X.readBox("unassigned").some((e) => e.id === id));
});
test("C4 a /pm-rename landing while close resolves the owner -> the note goes to the new tag's mailbox", () => {
  const pm = seed({ tag: "PM-cl4-old", issues: [10921] });
  G.setMap({ "o/r#10921": { pm: "PM-cl4-old" } });
  const s = wf();
  const id = recorded(s, "start", "#10921");
  G.side(P.statePath(pm), { tag: "PM-cl4-new", retired_tags: ["PM-cl4-old"] });
  let r;
  try { r = X.notify(["close"], { sid: s }); } finally { G.clearSide(); }
  assert.strictEqual(r.code, 0, brief(r));
  assert.deepStrictEqual(ids("PM-cl4-new"), [id], brief(r));
  assert.deepStrictEqual(ids("PM-cl4-old"), []);
});
caseEnd();

caseBegin("record-reuses-same-point-issue", "bin/lib/pm-notify/record.js");
test("N9 record twice for the same point and issue reuses the ID; the notification count stays 1", () => {
  const s = wf();
  const id = recorded(s, "start", "#10771");
  assert.strictEqual(recorded(s, "start", "o/r#10771"), id, JSON.stringify(X.notes(s)));
  assert.strictEqual(X.notes(s).length, 1, JSON.stringify(X.notes(s)));
});
test("N10 the same issue at another point, or another issue at the same point, gets its own ID", () => {
  const s = wf();
  const a = recorded(s, "start", "#10781");
  const b = recorded(s, "merge", "#10781");
  const c = recorded(s, "start", "#10782");
  assert.strictEqual(new Set([a, b, c]).size, 3, JSON.stringify(X.notes(s)));
  assert.strictEqual(X.notes(s).length, 3, JSON.stringify(X.notes(s)));
});
test("N11 a note already settled (ack) is not reused: a new record gets a new ID", () => {
  seed({ tag: "PM-nt11", issues: [10791] });
  G.setMap({ "o/r#10791": { pm: "PM-nt11" } });
  const s = wf();
  const id = recorded(s, "start", "#10791");
  assert.strictEqual(next(s).kv.ID, id);
  assert.strictEqual(settle(s, id, "ack").code, 0);
  const again = recorded(s, "start", "#10791");
  assert.notStrictEqual(again, id);
  assert.strictEqual(X.notes(s).length, 2, JSON.stringify(X.notes(s)));
});
caseEnd();

caseBegin("next-forge-state-bound-points", "bin/lib/pm-notify/next.js");
// A forge-bound note is sent while the issue is in its point's state (reopen: OPEN, merge: CLOSED), else dropped.
for (const [label, point, state, sends, num] of [
  ["a merge note whose issue is CLOSED is sent", "merge", "CLOSED", true, 10961],
  ["a merge note whose issue is OPEN again is dropped (forge-state-changed: OPEN)", "merge", "OPEN", false, 10962],
  ["a reopen note whose issue stayed OPEN is sent", "reopen", "OPEN", true, 10963],
]) {
  test(`N12 ${label}`, () => {
    const tag = `PM-nt12-${num}`;
    const pm = seed({ tag, issues: [num] });
    G.setMap({ [`o/r#${num}`]: { pm: tag, state } });
    const s = wf();
    const id = recorded(s, point, `#${num}`);
    const r = next(s);
    assert.strictEqual(r.code, 0, brief(r));
    const e = noteOf(s, id);
    if (sends) {
      assert.deepStrictEqual([r.kv.ID, r.kv.TAG, r.kv.SESSION, r.kv.POINT], [id, tag, pm, point], brief(r));
      assert.strictEqual(e.result, "sending", JSON.stringify(e));
    } else {
      assert.doesNotMatch(r.out, /SEND/, brief(r));
      assert.deepStrictEqual([e.result, e.reason], ["dropped", `forge-state-changed: ${state}`], JSON.stringify(e));
    }
  });
}
caseEnd();

// #2942: `record --issue N` (no `#`, which a shell reads as a comment) is the same ref as `--issue #N`.
caseBegin("record-issue-bare-number", "bin/lib/pm-notify/record.js");
test("N13 record --issue N keeps the same notification as --issue #N (one note, same ID)", () => {
  const s = wf();
  const r = X.notify(["record", "--point", "start", "--issue", "10971"], { sid: s });
  assert.strictEqual(r.code, 0, brief(r));
  assert.ok(r.kv.ID, brief(r));
  assert.strictEqual(recorded(s, "start", "#10971"), r.kv.ID, JSON.stringify(X.notes(s)));
  assert.strictEqual(X.notes(s).length, 1, JSON.stringify(X.notes(s)));
  assert.match(String(noteOf(s, r.kv.ID).issue), /^o\/r#10971$/);
});
for (const v of ["3.2", "0", "-1", "12abc"]) {
  test(`N14 record --issue ${v} -> exit 2 REASON=usage, nothing recorded`, () => {
    const s = wf();
    const r = X.notify(["record", "--point", "start", "--issue", v], { sid: s });
    assert.deepStrictEqual([r.code, r.kv.REASON], [2, "usage"], brief(r));
    assert.deepStrictEqual(X.notes(s), [], JSON.stringify(X.notes(s)));
  });
}
caseEnd();
