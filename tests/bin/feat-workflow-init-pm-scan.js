"use strict";
// Tests: bin/workflow/lib/workflow-init/phases/pm-scan.js, bin/workflow/workflow-init-driver
// Tags: TL2, scope:common, workflow-init, pm-session, pm-scan, issue-2942, issue-3168
// #2942 S13 / #3168: the pm-scan phase (between wip-check and route-decision) asks the owners of every issue in
// one batched lookup bounded by the 10 s scan budget, keeps the answer as the first record, blocks with multi-pm
// when two or more PMs own the issues (recording a notification to each), and carries on past an undecidable
// issue as undelivered.
// TL3 gap (what this test does NOT catch):
// - a full /workflow-init run through the skill, with the BLOCKED directive rendered to the user;
// - the 10 s budget against a real slow GitHub (a fake gh hang stands in for it here).
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const cwd0 = process.cwd();
// Registered before the fixture's own cleanup so the checkout is left before it is removed (Windows EPERM).
after(() => { process.chdir(cwd0); });
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
process.chdir(X.F.home);
after(() => { restore(); });

let n = 0;
const sid = () => P.uuid(0x29420800 + (++n));
const seed = (o) => { const s = sid(); P.seedPm(s, P.pm(o)); return s; };
// scan(nums) -> {r, s, ms}: the phase run for a fresh workflow session over issues nums of o/r.
function scan(nums) {
  const s = sid();
  P.seedState(s);
  const state = { issues: nums, label_sets: {}, repo_map: { 0: "o/r" }, wip_results: {}, issue_json_cache: {} };
  const mod = P.load("bin/workflow/lib/workflow-init/phases/pm-scan.js");
  assert.strictEqual(typeof mod.pmScan, "function", "pmScan is not exported");
  const t0 = Date.now();
  const r = mod.pmScan(state, s) || {};
  return { r, s, ms: Date.now() - t0 };
}
const recordText = (s) => JSON.stringify(P.raw(s));

// #2942: a failed notes write must not turn a known multi-pm into a pass. pm-scan reads C.updateNotes and (#3168)
// the batched C.ownersOf (through decidedOwnersOf) off the shared pm-notify/common exports at call time, so the
// cases swap them there and restore them.
const COMMON = require(path.join(P.ROOT, "bin", "lib", "pm-notify", "common"));
function scanWith(stubs, nums) {
  const saved = {};
  for (const k of Object.keys(stubs)) { saved[k] = COMMON[k]; COMMON[k] = stubs[k]; }
  try { return scan(nums); } finally { Object.assign(COMMON, saved); }
}
const ownersBy = (tags) => (refs) => ({ ok: true, answers: refs.map((ref) => ({ ok: true, owner: { tag: tags[ref.number], session_id: null } })) });
const notesFail = () => { throw new Error("notes write failed"); };
// The scan budget bound: wider than the retired 2000 ms per-issue cap, never past SCAN_BUDGET_MS (10000 ms).
const assertScanBudget = (ms) => assert.ok(ms > 2000 && ms <= 10000, `ownersOf timeoutMs ${ms} is not the 10 s scan budget`);

caseBegin("pm-scan-phase", "bin/workflow/lib/workflow-init/phases/pm-scan.js");
test("P1 one PM over every issue continues and keeps owner's answer as the first record", () => {
  seed({ tag: "PM-sc1", issues: [11101, 11102] });
  G.setMap({ "o/r#11101": { pm: "PM-sc1" }, "o/r#11102": { pm: "PM-sc1" } });
  const { r, s } = scan([11101, 11102]);
  assert.ok(!r.blocked && !r.ask, JSON.stringify(r));
  assert.match(recordText(s), /PM-sc1/, "the first owner record is missing from the workflow state");
});
test("P2 two PMs over the issues -> blocked multi-pm naming both tags and /pm-remove + /pm-add; each PM gets a notification", () => {
  seed({ tag: "PM-sc2a", issues: [11111] });
  seed({ tag: "PM-sc2b", issues: [11112] });
  G.setMap({ "o/r#11111": { pm: "PM-sc2a" }, "o/r#11112": { pm: "PM-sc2b" } });
  const { r, s } = scan([11111, 11112]);
  assert.ok(r.blocked, JSON.stringify(r));
  assert.strictEqual(r.reason, "multi-pm", JSON.stringify(r));
  const hint = String(r.hint || r.nextHint || "");
  for (const want of ["PM-sc2a", "PM-sc2b", "/pm-remove", "/pm-add"]) assert.ok(hint.includes(want), `hint lacks ${want}: ${hint}`);
  assert.ok(X.notes(s).length >= 2, JSON.stringify(X.notes(s)));
});
test("P3 an undecidable issue does not stop the scan; it is recorded as undelivered with its reason", () => {
  seed({ tag: "PM-sc3", issues: [11121] });
  G.setMap({ "o/r#11121": { pm: "PM-sc3" }, "o/r#11122": { pm: "PM-sc3-elsewhere" } });
  const { r, s } = scan([11121, 11122]);
  assert.ok(!r.blocked && !r.ask, JSON.stringify(r));
  const e = X.notes(s).find((x) => /11122/.test(String(x.issue)));
  assert.ok(e && e.result === "undelivered", JSON.stringify(X.notes(s)));
  assert.match(JSON.stringify(e), /tag-not-local/);
});
test("P4 no PM anywhere continues and records no notification", () => {
  G.setMap({ "o/r#11131": {} });
  const { r, s } = scan([11131]);
  assert.ok(!r.blocked && !r.ask, JSON.stringify(r));
  assert.deepStrictEqual(X.notes(s), []);
});
test("P5 a hung forge read is bounded by the 10 s scan budget and counted as undelivered", () => {
  G.setMap({ "o/r#11141": { pm: "PM-x" } });
  const real = COMMON.ownersOf;
  const passed = [];
  const spy = (refs, timeoutMs, ...rest) => { passed.push(timeoutMs); return real(refs, timeoutMs, ...rest); };
  G.sleep(15000);
  let res;
  try { res = scanWith({ ownersOf: spy }, [11141]); } finally { G.sleep(null); }
  assert.strictEqual(passed.length, 1, `ownersOf calls: ${JSON.stringify(passed)}`);
  assertScanBudget(passed[0]);
  assert.ok(!res.r.blocked, JSON.stringify(res.r));
  assert.ok(res.ms > 2500 && res.ms < 13000, `pm-scan waited ${res.ms} ms on a forge read hung for 15 s`);
  const e = X.notes(res.s).find((x) => /11141/.test(String(x.issue)));
  assert.ok(e && e.result === "undelivered", JSON.stringify(X.notes(res.s)));
});
test("P6 an issue whose repo cannot be resolved is kept as an undelivered start (#N, repo-unresolved), once across reruns", () => {
  G.setMap({ "o/r#11151": {} });
  const s = sid();
  P.seedState(s);
  // A child process in an origin-less dir: the home repo is cached per process, and this process's is o/r.
  const bare = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "pm-scan-bare-"));
  const code = "const m=require(process.argv[1]);const st={issues:[11151,11152],label_sets:{},repo_map:{0:'o/r'},wip_results:{},issue_json_cache:{}};process.stdout.write(JSON.stringify(m.pmScan(st,process.argv[2])||{}))";
  const runScan = () => require("node:child_process").spawnSync(process.execPath, ["-e", code, path.join(P.ROOT, "bin", "workflow", "lib", "workflow-init", "phases", "pm-scan.js"), s], { cwd: bare, env: process.env, encoding: "utf8", timeout: 60000 });
  let r;
  try { r = runScan(); runScan(); } finally { fs.rmSync(bare, { recursive: true, force: true }); }
  assert.doesNotMatch(String(r.stdout), /blocked/, `${r.stdout}${r.stderr}`);
  const got = X.notes(s).filter((x) => /11152/.test(String(x.issue)));
  assert.strictEqual(got.length, 1, JSON.stringify(X.notes(s)));
  assert.deepStrictEqual([got[0].issue, got[0].point, got[0].result, got[0].reason], ["#11152", "start", "undelivered", "repo-unresolved"]);
});
caseEnd();

caseBegin("pm-scan-phase-order", "bin/workflow/workflow-init-driver");
test("O1 PHASE_ORDER runs pm-scan right after wip-check and before route-decision, with a dispatch arm", () => {
  const src = fs.readFileSync(path.join(P.ROOT, "bin", "workflow", "workflow-init-driver"), "utf8");
  const m = /const\s+PHASE_ORDER\s*=\s*\[([\s\S]*?)\]\s*;/.exec(src);
  const order = (m ? m[1] : "").split("\n").map((l) => l.replace(/\/\/.*$/, "")).join("").match(/"[^"]+"/g) || [];
  const i = order.indexOf('"pm-scan"');
  assert.ok(i > 0 && order[i - 1] === '"wip-check"' && order[i + 1] === '"route-decision"', order.join(","));
  assert.match(src, /phase === "pm-scan"/);
});
caseEnd();

caseBegin("pm-scan-multi-pm-notes-exact", "bin/workflow/lib/workflow-init/phases/pm-scan.js");
test("P7 three issues under two PMs -> exactly one multi-pm note per PM, addressed by to_tag, none for the shared PM's second issue", () => {
  seed({ tag: "PM-sc7a", issues: [11161, 11162] });
  seed({ tag: "PM-sc7b", issues: [11163] });
  G.setMap({ "o/r#11161": { pm: "PM-sc7a" }, "o/r#11162": { pm: "PM-sc7a" }, "o/r#11163": { pm: "PM-sc7b" } });
  const { r, s } = scan([11161, 11162, 11163]);
  assert.strictEqual(r.reason, "multi-pm", JSON.stringify(r));
  const got = X.notes(s);
  assert.strictEqual(got.length, 2, JSON.stringify(got));
  assert.deepStrictEqual(got.map((e) => e.to_tag).sort(), ["PM-sc7a", "PM-sc7b"], JSON.stringify(got));
  assert.ok(got.every((e) => e.point === "multi-pm" && e.result === "pending"), JSON.stringify(got));
});
test("P8 a rerun of the blocked scan in the same session adds no second note per PM", () => {
  seed({ tag: "PM-sc8a", issues: [11171] });
  seed({ tag: "PM-sc8b", issues: [11172] });
  G.setMap({ "o/r#11171": { pm: "PM-sc8a" }, "o/r#11172": { pm: "PM-sc8b" } });
  const { s } = scan([11171, 11172]);
  const state = { issues: [11171, 11172], label_sets: {}, repo_map: { 0: "o/r" }, wip_results: {}, issue_json_cache: {} };
  const r2 = P.load("bin/workflow/lib/workflow-init/phases/pm-scan.js").pmScan(state, s) || {};
  assert.strictEqual(r2.reason, "multi-pm", JSON.stringify(r2));
  assert.deepStrictEqual(X.notes(s).map((e) => e.to_tag).sort(), ["PM-sc8a", "PM-sc8b"], JSON.stringify(X.notes(s)));
});
caseEnd();

caseBegin("pm-scan-multi-pm-survives-notes-failure", "bin/workflow/lib/workflow-init/phases/pm-scan.js");
test("C17 two owners and updateNotes throws -> still blocked multi-pm, the hint naming both tags", () => {
  const { r } = scanWith({ ownersOf: ownersBy({ 11181: "PM-c17a", 11182: "PM-c17b" }), updateNotes: notesFail }, [11181, 11182]);
  assert.strictEqual(r.blocked, true, `a notes failure hid multi-pm: ${JSON.stringify(r)}`);
  assert.strictEqual(r.reason, "multi-pm", JSON.stringify(r));
  for (const want of ["PM-c17a", "PM-c17b"]) assert.ok(String(r.hint).includes(want), `hint lacks ${want}: ${r.hint}`);
});
test("C17 one owner and updateNotes throws -> fail-open {done:false}", () => {
  const { r } = scanWith({ ownersOf: ownersBy({ 11183: "PM-c17c", 11184: "PM-c17c" }), updateNotes: notesFail }, [11183, 11184]);
  assert.deepStrictEqual(r, { done: false });
});
test("C17 an error before the owners are known (owner lookup throws) -> fail-open {done:false}", () => {
  const { r } = scanWith({ ownersOf: () => { throw new Error("ask failed"); } }, [11185, 11186]);
  assert.deepStrictEqual(r, { done: false });
});
caseEnd();

// #3168: pm-scan calls ownersOf exactly once regardless of the issue count, carrying every issue in that one call.
// A whole failure ({ok:false, reason}) is not thrown; every ref flows through the current path as {ref, r:{ok:false, reason}}.
caseBegin("pm-scan-one-batched-owner-call", "bin/workflow/lib/workflow-init/phases/pm-scan.js");
test("P9 three issues are asked in one ownersOf call carrying every issue, bounded by the scan budget", () => {
  const calls = [];
  const spy = (refs, timeoutMs) => { calls.push({ nums: refs.map((x) => x.number), timeoutMs }); return ownersBy({ 11191: "PM-p9", 11192: "PM-p9", 11193: "PM-p9" })(refs); };
  const { r } = scanWith({ ownersOf: spy }, [11191, 11192, 11193]);
  assert.ok(!r.blocked, JSON.stringify(r));
  assert.strictEqual(calls.length, 1, `ownersOf calls: ${JSON.stringify(calls)}`);
  assert.deepStrictEqual([...calls[0].nums].sort(), [11191, 11192, 11193], JSON.stringify(calls));
  assertScanBudget(calls[0].timeoutMs);
});
test("P10 ownersOf whole failure (timeout): records every issue as undelivered with reason timeout, does not stop on multi-pm", () => {
  // The forge (fake gh) answers 2 PMs. A path that bypasses the stubbed ownersOf blocks on multi-pm, so it goes red.
  seed({ tag: "PM-p10a", issues: [11194] });
  seed({ tag: "PM-p10b", issues: [11195] });
  G.setMap({ "o/r#11194": { pm: "PM-p10a" }, "o/r#11195": { pm: "PM-p10b" } });
  const calls = [];
  const fail = (refs) => { calls.push(refs.map((x) => x.number)); return { ok: false, reason: "timeout" }; };
  const { r, s } = scanWith({ ownersOf: fail }, [11194, 11195]);
  assert.strictEqual(calls.length, 1, `ownersOf calls: ${JSON.stringify(calls)}`);
  assert.ok(!r.blocked && !r.ask, `a whole failure blocked the scan: ${JSON.stringify(r)}`);
  for (const num of [11194, 11195]) {
    const e = X.notes(s).find((x) => new RegExp(String(num)).test(String(x.issue)));
    assert.ok(e && e.result === "undelivered" && e.reason === "timeout", `${num} is not an undelivered timeout: ${JSON.stringify(X.notes(s))}`);
  }
});
caseEnd();
