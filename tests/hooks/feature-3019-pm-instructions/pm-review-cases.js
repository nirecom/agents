"use strict";
// #3144 C3 cases of tests/hooks/feature-3019-pm-instructions.js: the two review timings leave the workflow
// session-start bundle and are fetched one by one through --timing; the split :83 checklist line, and the
// RR-5 pointers of pm-pre-pr-contact.md `## Review request` to both duty headings. No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const W8 = require("./world");

const { ROOT, SSOT_MD, P, MD_ENV, byKey, mark, fixtureMd, headingPairs, makeWorld, brief, firstLine } = W8;
const CONTACT_MD = path.join(ROOT, "skills", "_shared", "pm-pre-pr-contact.md");
const SECTIONS = path.join(ROOT, "hooks", "lib", "pm-instructions", "sections.js");
const H_PLAN = "### Before plan confirmation sentinel";
const H_UV = "### Before user verification";
const REVIEW_TIMINGS = ["before-plan-confirm", "before-user-verification"];
const read = (f) => fs.readFileSync(f, "utf8");
// section(text, re) -> from the heading matching re up to the next heading of the same or a higher level.
function section(text, re) {
  const lines = String(text).split(/\r?\n/);
  const i = lines.findIndex((l) => re.test(l));
  if (i < 0) return null;
  const level = /^#+/.exec(lines[i])[0].length;
  const end = lines.findIndex((l, j) => j > i && /^#+ /.test(l) && /^#+/.exec(l)[0].length <= level);
  return lines.slice(i, end < 0 ? lines.length : end).join("\n");
}
const bodyLines = (text) => String(text).split(/\r?\n/).filter((l) => /^\s*- /.test(l));

// bundle: BUNDLES.workflow is issue-start only; the session-start render of the workflow role carries the
// issue-start section and neither review timing, while --timing still returns each one alone.
function bundle(S) {
  test("3144 C3: BUNDLES.workflow is issue-start only; pm keeps session-start", () => {
    const sec = require(SECTIONS);
    assert.deepStrictEqual([...sec.BUNDLES.workflow], ["issue-start"]);
    assert.deepStrictEqual([...sec.BUNDLES.pm], ["session-start"]);
    for (const t of REVIEW_TIMINGS) assert.ok(sec.TIMINGS.includes(t), `TIMINGS keeps ${t}`);
  });
  const w = makeWorld(S, "pm-review-bundle");
  const md = { [MD_ENV]: S.md("pm-review-bundle", fixtureMd()) };
  const pmSid = P.uuid(0x31440001);
  const wf = P.uuid(0x31440002);
  w.pm(pmSid, P.pm({ tag: "PM-rev", issues: [4971] }));
  w.plain(wf);
  w.intent(wf, ["#4971"]);
  w.field({ "o/r#4971": "PM-rev" });
  test("3144 C3: the workflow session-start bundle carries issue-start and neither review timing", () => {
    const r = w.cli(["--timing", "session-start", "--session", wf], md);
    assert.strictEqual(r.code, 0, brief(r));
    assert.strictEqual(firstLine(r.out), "[pm-instructions role=workflow timing=session-start]", brief(r));
    assert.ok(r.out.includes(mark(byKey("workflow", "issue-start"))), brief(r));
    for (const t of REVIEW_TIMINGS) assert.ok(!r.out.includes(mark(byKey("workflow", t))), `${t} still bundled: ${brief(r)}`);
  });
  for (const t of REVIEW_TIMINGS) {
    test(`3144 C3: --timing ${t} returns that section alone`, () => {
      const r = w.cli(["--timing", t, "--session", wf], md);
      assert.strictEqual(r.code, 0, brief(r));
      assert.strictEqual(firstLine(r.out), `[pm-instructions role=workflow timing=${t}]`, brief(r));
      assert.ok(r.out.includes(mark(byKey("workflow", t))), brief(r));
      assert.ok(!r.out.includes(mark(byKey("workflow", "issue-start"))), brief(r));
    });
  }
  // The real md (no MD_ENV): the split :83 lines reach the session through --timing before-user-verification.
  test("3144 C3: real --timing before-user-verification carries the PR-review checklist line and the get-release-approval procedure line", () => {
    const r = w.cli(["--timing", "before-user-verification", "--session", wf]);
    assert.strictEqual(r.code, 0, brief(r));
    const lines = bodyLines(r.out);
    const check = lines.filter((l) => /\bPR\b/.test(l) && /review/i.test(l) && !/get-release-approval/.test(l));
    const proc = lines.filter((l) => /get-release-approval/.test(l) && /## Review request/.test(l));
    assert.ok(check.length >= 1, `no checklist line naming the PR as the review target: ${brief(r)}`);
    assert.ok(proc.length >= 1, `no get-release-approval / ## Review request procedure line: ${brief(r)}`);
    assert.ok(!r.out.includes("[interim: #2991]"), brief(r));
  });
  test("3144 C3: real --timing before-plan-confirm keeps the copy check and points at the audit-wait hint and ## Review request", () => {
    const r = w.cli(["--timing", "before-plan-confirm", "--session", wf]);
    assert.strictEqual(r.code, 0, brief(r));
    const lines = bodyLines(r.out);
    assert.ok(lines.some((l) => /copied from a parent issue/i.test(l)), `copy check gone: ${brief(r)}`);
    assert.ok(lines.some((l) => /audit-wait/.test(l) && /## Review request/.test(l)), `no audit-wait / ## Review request line: ${brief(r)}`);
    assert.ok(!r.out.includes("[interim: #2991]"), brief(r));
  });
}

// duties: the SSOT md drops every [interim: #2991], keeps both headings, and tells the PM how to answer a review request.
function duties() {
  test("3144 C3: pm-supervisor-duties.md has no [interim: #2991] and keeps both review headings once", () => {
    const md = read(SSOT_MD);
    assert.ok(!md.includes("[interim: #2991]"), "[interim: #2991] remains");
    const { pairs } = headingPairs(md);
    assert.strictEqual(pairs.get("Workflow session/Before plan confirmation sentinel"), 1);
    assert.strictEqual(pairs.get("Workflow session/Before user verification"), 1);
  });
  test("3144 C3: Before user verification is split into a checklist line and a procedure line", () => {
    const body = section(section(read(SSOT_MD), /^## Workflow session\s*$/), /^### Before user verification\s*$/);
    assert.ok(body, "no ### Before user verification");
    const lines = bodyLines(body);
    assert.ok(lines.length >= 2, `expected at least 2 lines: ${body}`);
    assert.ok(lines.some((l) => /\bPR\b/.test(l) && /review/i.test(l) && !/get-release-approval/.test(l)), body);
    assert.ok(lines.some((l) => /get-release-approval/.test(l) && /pm-pre-pr-contact\.md/.test(l) && /## Review request/.test(l)), body);
  });
  test("3144 C3: PM session start tells the PM to answer a review request with a verdict and a peer-ack naming the heading", () => {
    const body = section(section(read(SSOT_MD), /^## PM session\s*$/), /^### Session start\s*$/);
    const line = bodyLines(body).find((l) => /review request/i.test(l));
    assert.ok(line, `no review-request line: ${body}`);
    for (const re of [/RR-5/, /--format pm-review/, /--high/, /peer-ack/, /heading/i]) assert.ok(re.test(line), `${re}: ${line}`);
  });
}

// contact: pm-pre-pr-contact.md gains `## Review request`; RR-1 calls both timings and RR-5 points at both headings,
// one per trigger, and both headings exist in the duties md.
function contact() {
  test("3144 C3: pm-pre-pr-contact.md has the new H1 and a ## Review request section with RR-1..RR-6", () => {
    const md = read(CONTACT_MD);
    assert.strictEqual(md.split(/\r?\n/)[0], "# PM Contact (pre-PR and review)");
    const rr = section(md, /^## Review request\s*$/);
    assert.ok(rr, "no ## Review request section");
    for (const id of ["RR-1", "RR-2", "RR-3", "RR-4", "RR-5", "RR-6"]) assert.ok(rr.includes(id), `${id} missing`);
    for (const t of REVIEW_TIMINGS) assert.ok(rr.includes(t), `RR-1 does not name --timing ${t}`);
  });
  test("3144 C3: RR-5 points at both duty headings, one per trigger, and both exist in pm-supervisor-duties.md", () => {
    const rr = section(read(CONTACT_MD), /^## Review request\s*$/) || "";
    const rr5 = rr.split(/\r?\n/).filter((l) => /RR-5/.test(l)).join("\n");
    assert.ok(rr5, `no RR-5 line: ${rr}`);
    assert.ok(rr5.includes("pm-supervisor-duties.md"), rr5);
    assert.ok(rr5.includes(H_PLAN), `RR-5 lacks ${H_PLAN}: ${rr5}`);
    assert.ok(rr5.includes(H_UV), `RR-5 lacks ${H_UV}: ${rr5}`);
    assert.ok(/plan[^\n]*Before plan confirmation sentinel/i.test(rr5), `plan trigger not tied to its heading: ${rr5}`);
    assert.ok(/user_verified[^\n]*Before user verification|USER_VERIFIED[^\n]*Before user verification/.test(rr5), `user_verified trigger not tied to its heading: ${rr5}`);
    const duty = read(SSOT_MD).split(/\r?\n/);
    for (const h of [H_PLAN, H_UV]) assert.ok(duty.includes(h), `${h} is not a heading of pm-supervisor-duties.md`);
  });
}

module.exports = { bundle, duties, contact };
