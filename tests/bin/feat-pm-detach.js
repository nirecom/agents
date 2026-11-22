"use strict";
// Tests: bin/lib/pm-notify/detach.js, bin/lib/pm-notify/inbox.js
// Tags: TL2, scope:common, pm-session, pm-notify, pm-detach, issue-2942
// #2942 outline decision 7: a child taken off its meta parent is told to the PM that owned it before.
// Inside the workflow `detach --issue <ref> --phase before|after` brackets the dispatch; outside it the next
// notification point sees the first owner record differ from `owner`; the PM side compares pm.meta_children
// with the current children; a detach seen by both sides is shown once per issue.
// TL3 gap (what this test does NOT catch):
// - issue-create-dispatch.sh make-parent --children calling detach around a real GitHub edit;
// - the SendMessage of the detach notification to a live PM session (pm-notify.md loop).
const { test, after } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
after(() => { restore(); });

let n = 0;
const sid = () => P.uuid(0x29420900 + (++n));
const seed = (o) => { const s = sid(); P.seedPm(s, P.pm(o)); return s; };
const brief = (r) => JSON.stringify({ code: r.code, out: r.out, err: r.err });
const detachNotes = (s, num) => X.notes(s).filter((e) => e.point === "detach" && new RegExp(`#${num}\\b`).test(String(e.issue)));
// drain(s) -> every SEND line `next` prints for workflow session s until it prints none (at most 6 rounds).
function drain(s) {
  const sends = [];
  for (let i = 0; i < 6; i++) {
    const r = X.notify(["next"], { sid: s });
    const got = r.lines.filter((l) => /SEND/.test(l) || /^TAG=/.test(l));
    if (!got.length) break;
    sends.push(r.out);
  }
  return sends.join("\n");
}

caseBegin("detach-workflow-side", "bin/lib/pm-notify/detach.js");
test("D1 a detach done inside the workflow is recorded for the PM that owned the child before, and next sends it there", () => {
  seed({ tag: "PM-dt1", issues: [11201] });
  G.setMap({ "o/r#11201": { pm: "PM-dt1" }, "o/r#11202": { parent: { number: 11201 } } });
  const s = sid();
  P.seedState(s);
  const before = X.notify(["detach", "--issue", "o/r#11202", "--phase", "before"], { sid: s });
  assert.strictEqual(before.code, 0, brief(before));
  G.setMap({ "o/r#11201": { pm: "PM-dt1" }, "o/r#11202": {} });
  const afterR = X.notify(["detach", "--issue", "o/r#11202", "--phase", "after"], { sid: s });
  assert.strictEqual(afterR.code, 0, brief(afterR));
  const e = detachNotes(s, 11202);
  assert.strictEqual(e.length, 1, JSON.stringify(X.notes(s)));
  assert.match(JSON.stringify(e[0]), /PM-dt1/, "the detach notification does not name the former PM");
  assert.match(drain(s), /TAG=PM-dt1/);
});
test("D1b a dispatch that leaves the owner unchanged records no detach", () => {
  seed({ tag: "PM-dt1b", issues: [11211] });
  G.setMap({ "o/r#11211": { pm: "PM-dt1b" }, "o/r#11212": { parent: { number: 11211 } } });
  const s = sid();
  P.seedState(s);
  X.notify(["detach", "--issue", "o/r#11212", "--phase", "before"], { sid: s });
  const r = X.notify(["detach", "--issue", "o/r#11212", "--phase", "after"], { sid: s });
  assert.strictEqual(r.code, 0, brief(r));
  assert.deepStrictEqual(detachNotes(s, 11212), [], JSON.stringify(X.notes(s)));
});
test("D2 a detach done outside the workflow is found at the next notification point and also told to the first owner", () => {
  seed({ tag: "PM-dt2", issues: [11221] });
  seed({ tag: "PM-dt2-new", issues: [11222] });
  G.setMap({ "o/r#11221": { pm: "PM-dt2" }, "o/r#11222": { parent: { number: 11221 } } });
  const s = sid();
  P.seedState(s);
  const state = { issues: [11222], label_sets: {}, repo_map: { 0: "o/r" }, wip_results: {}, issue_json_cache: {} };
  const c = process.cwd();
  process.chdir(X.F.home);
  try { P.load("bin/workflow/lib/workflow-init/phases/pm-scan.js").pmScan(state, s); } finally { process.chdir(c); }
  G.setMap({ "o/r#11221": { pm: "PM-dt2" }, "o/r#11222": { pm: "PM-dt2-new" } });
  const rec = X.notify(["record", "--point", "scope-change", "--issue", "o/r#11222"], { sid: s });
  assert.strictEqual(rec.code, 0, brief(rec));
  const sent = drain(s);
  assert.match(sent, /TAG=PM-dt2\b/, `the first owner was not told: ${sent}`);
  assert.match(sent, /TAG=PM-dt2-new/, `the current owner lost its own notification: ${sent}`);
  assert.strictEqual(detachNotes(s, 11222).length, 1, JSON.stringify(X.notes(s)));
});
caseEnd();

caseBegin("detach-pm-side", "bin/lib/pm-notify/inbox.js");
test("D3 inbox --pm shows a child gone from a meta's sub-issues as a detach and updates meta_children", () => {
  const pm = seed({ tag: "PM-dt3", issues: [11231] });
  const st = P.raw(pm);
  st.pm.meta_children = { "o/r#11231": ["o/r#11232", "o/r#11233"] };
  P.writeRaw(pm, st);
  G.setMap({ "o/r#11231": { pm: "PM-dt3" }, "o/r#11232": { parent: { number: 11231 } }, "o/r#11233": {} });
  const r = X.notify(["inbox", "--pm"], { sid: pm });
  assert.match(r.out, /11233/, brief(r));
  assert.match(r.out, /detach/i, brief(r));
  assert.doesNotMatch(r.out, /11232/, brief(r));
  assert.deepStrictEqual(P.readPm(pm).meta_children["o/r#11231"], ["o/r#11232"]);
  const again = X.notify(["inbox", "--pm"], { sid: pm });
  assert.doesNotMatch(again.out, /11233/, `the same detach was shown twice: ${brief(again)}`);
});
test("D4 a detach seen by both the workflow side (mailbox) and the PM side is shown once for the issue", () => {
  const pm = seed({ tag: "PM-dt4", issues: [11241] });
  const st = P.raw(pm);
  st.pm.meta_children = { "o/r#11241": ["o/r#11242"] };
  P.writeRaw(pm, st);
  G.setMap({ "o/r#11241": { pm: "PM-dt4" }, "o/r#11242": {} });
  X.writeBox("PM-dt4", [{ id: "n-dt4", point: "detach", issue: "o/r#11242", from_session: "sess-dt4", at: "2026-11-20T00:00:00.000Z" }]);
  const r = X.notify(["inbox", "--pm"], { sid: pm });
  const hits = r.lines.filter((l) => /11242/.test(l));
  assert.strictEqual(hits.length, 1, brief(r));
});
test("D5 an assigned issue missing from meta_children takes its children as the baseline (no detach), then a removal is a detach", () => {
  const pm = seed({ tag: "PM-dt5", issues: [11251] });
  G.setMap({ "o/r#11251": { pm: "PM-dt5" }, "o/r#11252": { parent: { number: 11251 } } });
  const first = X.notify(["inbox", "--pm"], { sid: pm });
  assert.doesNotMatch(first.out, /detach/i, brief(first));
  assert.deepStrictEqual(P.readPm(pm).meta_children, { "o/r#11251": ["o/r#11252"] });
  G.setMap({ "o/r#11251": { pm: "PM-dt5" }, "o/r#11252": {} });
  const second = X.notify(["inbox", "--pm"], { sid: pm });
  assert.match(second.out, /detach: o\/r#11252/, brief(second));
});
test("D6 an assigned leaf records no baseline, and an unread forge with empty meta_children prints no skip line", () => {
  const pm = seed({ tag: "PM-dt6", issues: [11261] });
  G.setMap({ "o/r#11261": { pm: "PM-dt6" } });
  const r = X.notify(["inbox", "--pm"], { sid: pm });
  assert.doesNotMatch(r.out, /detach/i, brief(r));
  assert.ok(!P.readPm(pm).meta_children || Object.keys(P.readPm(pm).meta_children).length === 0, JSON.stringify(P.readPm(pm)));
  G.mode("fail");
  let failed;
  try { failed = X.notify(["inbox", "--pm"], { sid: pm }); } finally { G.mode(null); }
  assert.doesNotMatch(failed.out, /meta detach check skipped/, brief(failed));
});
caseEnd();
