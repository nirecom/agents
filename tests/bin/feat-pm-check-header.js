"use strict";
// Tests: bin/lib/pm-notify/check-header.js
// Tags: TL2, scope:common, pm-session, pm-notify, check-header, issue-2942
// #2942 S11: `bin/pm-notify check-header --tag <t> --pm-issues <#A,#B> --closes <#C>` (CP-1b) compares the header's
// whole pm-issues set with the tag's current generation, and reports the owner of closes_issues as OWNER_TAG.
// TL3 gap (what this test does NOT catch):
// - a header received over a real SendMessage from a live PM session;
// - the AskUserQuestion that pm-pre-pr-contact.md shows for mismatch and undecidable.
const { test, after } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
after(() => { restore(); });

let n = 0;
const sid = () => P.uuid(0x29420600 + (++n));
const seed = (o) => { const s = sid(); P.seedPm(s, P.pm(o)); return s; };
const check = (tag, issues, closes) => X.notify(["check-header", "--tag", tag, "--pm-issues", issues, "--closes", closes]);
const listOf = (v) => String(v || "").split(",").filter(Boolean).sort();
const brief = (r) => JSON.stringify({ code: r.code, out: r.out, err: r.err });

caseBegin("check-header-compares-the-whole-set", "bin/lib/pm-notify/check-header.js");
test("H1 the header's set equals the assigned issue list and closes is owned by the tag -> RESULT=ok", () => {
  seed({ tag: "PM-ch1", issues: [10601, 10602] });
  G.setMap({ "o/r#10601": { pm: "PM-ch1" }, "o/r#10602": { pm: "PM-ch1" } });
  const r = check("PM-ch1", "#10601,#10602", "#10601");
  assert.strictEqual(r.kv.RESULT, "ok", brief(r));
  assert.deepStrictEqual(listOf(r.kv.EXTRA), [], brief(r));
  assert.deepStrictEqual(listOf(r.kv.MISSING), [], brief(r));
  assert.strictEqual(r.kv.OWNER_TAG, "PM-ch1", brief(r));
});
test("H2 the header names an issue outside the assignment -> RESULT=mismatch, EXTRA lists it", () => {
  seed({ tag: "PM-ch2", issues: [10611, 10612] });
  G.setMap({ "o/r#10611": { pm: "PM-ch2" }, "o/r#10612": { pm: "PM-ch2" } });
  const r = check("PM-ch2", "#10611,#10612,#10613", "#10611");
  assert.strictEqual(r.kv.RESULT, "mismatch", brief(r));
  assert.deepStrictEqual(listOf(r.kv.EXTRA), ["#10613"], brief(r));
  assert.deepStrictEqual(listOf(r.kv.MISSING), [], brief(r));
});
test("H3 the header lacks an assigned issue -> RESULT=mismatch, MISSING lists it", () => {
  seed({ tag: "PM-ch3", issues: [10621, 10622] });
  G.setMap({ "o/r#10621": { pm: "PM-ch3" }, "o/r#10622": { pm: "PM-ch3" } });
  const r = check("PM-ch3", "#10621", "#10621");
  assert.strictEqual(r.kv.RESULT, "mismatch", brief(r));
  assert.deepStrictEqual(listOf(r.kv.MISSING), ["#10622"], brief(r));
});
test("H4 closes_issues owned by the tag does not hide an out-of-scope issue in the header", () => {
  seed({ tag: "PM-ch4", issues: [10631] });
  G.setMap({ "o/r#10631": { pm: "PM-ch4" } });
  const r = check("PM-ch4", "#10631,#10639", "#10631");
  assert.strictEqual(r.kv.OWNER_TAG, "PM-ch4", brief(r));
  assert.strictEqual(r.kv.RESULT, "mismatch", brief(r));
  assert.deepStrictEqual(listOf(r.kv.EXTRA), ["#10639"], brief(r));
});
test("H5 owner/repo#N and #N of the home repo are the same issue (normalizeRef) -> RESULT=ok", () => {
  seed({ tag: "PM-ch5", issues: [10641] });
  G.setMap({ "o/r#10641": { pm: "PM-ch5" } });
  const r = check("PM-ch5", "o/r#10641", "#10641");
  assert.strictEqual(r.kv.RESULT, "ok", brief(r));
});
test("H6 the comparison uses the tag's current generation, not an older one", () => {
  seed({ tag: "PM-ch6", issues: [10651], current_since: "2026-11-01T00:00:00.000Z" });
  seed({ tag: "PM-ch6", issues: [10651, 10652], current_since: "2026-11-04T00:00:00.000Z" });
  G.setMap({ "o/r#10651": { pm: "PM-ch6" }, "o/r#10652": { pm: "PM-ch6" } });
  const r = check("PM-ch6", "#10651,#10652", "#10651");
  assert.strictEqual(r.kv.RESULT, "ok", brief(r));
});
caseEnd();

caseBegin("check-header-empty-pm-issues", "bin/lib/pm-notify/check-header.js");
test("H7 an empty --pm-issues (no recorded header) skips EXTRA/MISSING; the owner of closes decides ok", () => {
  seed({ tag: "PM-ch7", issues: [10691, 10692] });
  G.setMap({ "o/r#10691": { pm: "PM-ch7" }, "o/r#10692": { pm: "PM-ch7" } });
  const r = check("PM-ch7", "", "#10691");
  assert.strictEqual(r.kv.RESULT, "ok", brief(r));
  assert.deepStrictEqual([listOf(r.kv.EXTRA), listOf(r.kv.MISSING)], [[], []], brief(r));
  assert.strictEqual(r.kv.OWNER_TAG, "PM-ch7", brief(r));
});
test("H8 an empty --pm-issues with closes owned by another PM -> RESULT=mismatch owner-differs", () => {
  seed({ tag: "PM-ch8", issues: [10693] });
  seed({ tag: "PM-ch8-other", issues: [10694] });
  G.setMap({ "o/r#10693": { pm: "PM-ch8" }, "o/r#10694": { pm: "PM-ch8-other" } });
  const r = check("PM-ch8", "", "#10694");
  assert.strictEqual(r.kv.RESULT, "mismatch", brief(r));
  assert.strictEqual(r.kv.REASON, "owner-differs", brief(r));
  assert.deepStrictEqual(listOf(r.kv.MISSING), [], brief(r));
});
caseEnd();

caseBegin("check-header-undecidable", "bin/lib/pm-notify/check-header.js");
test("U1 a tag no PM state on this PC holds -> RESULT=undecidable naming tag-not-local", () => {
  G.setMap({ "o/r#10661": { pm: "PM-far-away" } });
  const r = check("PM-far-away", "#10661", "#10661");
  assert.strictEqual(r.kv.RESULT, "undecidable", brief(r));
  assert.match(r.out + r.err, /tag-not-local/);
});
test("U2 the owner of closes_issues cannot be read from the forge -> RESULT=undecidable, not ok", () => {
  seed({ tag: "PM-chu2", issues: [10671] });
  G.setMap({ "o/r#10671": { pm: "PM-chu2" } });
  G.mode("fail");
  let r;
  try { r = check("PM-chu2", "#10671", "#10671"); } finally { G.mode(null); }
  assert.strictEqual(r.kv.RESULT, "undecidable", brief(r));
});
test("U3 a tag retired by /pm-rename is refused with REASON=pm-tag-renamed and NEW_TAG", () => {
  const s = seed({ tag: "PM-chu3-new", issues: [10681] });
  const st = P.raw(s);
  st.pm.retired_tags = ["PM-chu3-old"];
  P.writeRaw(s, st);
  const r = check("PM-chu3-old", "#10681", "#10681");
  assert.notStrictEqual(r.code, 0, brief(r));
  assert.strictEqual(r.kv.REASON, "pm-tag-renamed", brief(r));
  assert.strictEqual(r.kv.NEW_TAG, "PM-chu3-new", brief(r));
});
caseEnd();

// The header end to end: the real `bin/peer-msg header --role pm` run as a PM session (isolated state, no
// agents list: the production name policy falls back to reply-to=from), its pm-issues fed to check-header.
const cp = require("node:child_process");
const path = require("node:path");
function pmHeader(s) {
  const env = Object.assign({}, process.env, { CLAUDE_CODE_SESSION_ID: s });
  const r = cp.spawnSync("bash", ["-c", '"$0" "$@"', P.fwd(path.join(P.ROOT, "bin", "peer-msg")), "header", "--role", "pm"], { cwd: X.F.home, env, encoding: "utf8", timeout: 60000 });
  const line = String(r.stdout || "").split(/\r?\n/).find((l) => l.startsWith("[peer-msg v1] ")) || "";
  const m = / role=pm pm-issues=(\S+)$/.exec(line);
  return { code: r.status, issues: m ? m[1] : null, brief: `${r.stdout}${r.stderr}` };
}
caseBegin("check-header-from-the-real-peer-msg-header", "bin/lib/pm-notify/check-header.js");
test("H9 the current generation's header names its whole assigned list and check-header accepts it (RESULT=ok)", () => {
  seed({ tag: "PM-ch9", issues: [10701], current_since: "2026-11-01T00:00:00.000Z" });
  const cur = seed({ tag: "PM-ch9", issues: [10701, 10702], current_since: "2026-11-04T00:00:00.000Z" });
  G.setMap({ "o/r#10701": { pm: "PM-ch9" }, "o/r#10702": { pm: "PM-ch9" } });
  const h = pmHeader(cur);
  assert.strictEqual(h.code, 0, h.brief);
  assert.deepStrictEqual(listOf(h.issues), ["#10701", "#10702"], h.brief);
  const r = check("PM-ch9", h.issues, "#10702");
  assert.strictEqual(r.kv.RESULT, "ok", brief(r));
  assert.deepStrictEqual([listOf(r.kv.EXTRA), listOf(r.kv.MISSING)], [[], []], brief(r));
});
test("H10 a header sent from an older generation's session of the tag names the current generation's list", () => {
  const old = seed({ tag: "PM-ch10", issues: [10711], current_since: "2026-11-01T00:00:00.000Z" });
  seed({ tag: "PM-ch10", issues: [10711, 10712], current_since: "2026-11-04T00:00:00.000Z" });
  G.setMap({ "o/r#10711": { pm: "PM-ch10" }, "o/r#10712": { pm: "PM-ch10" } });
  const h = pmHeader(old);
  assert.strictEqual(h.code, 0, h.brief);
  assert.deepStrictEqual(listOf(h.issues), ["#10711", "#10712"], h.brief);
});
caseEnd();
