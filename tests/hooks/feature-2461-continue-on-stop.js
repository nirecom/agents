#!/usr/bin/env node
// tests/hooks/feature-2461-continue-on-stop.js
// Tests: hooks/lib/jev-continue-on-stop.js, hooks/stop-premature-stop-guard.js, hooks/lib/stop-exemption-policy.js
// Tags: TL2, hooks, jev, stop-guard, continue-on-stop, continuation, exemption, mock-server, scope:issue-specific, pwsh-not-required
// #2461 Step 4: when the stop guard would let a stop through, it asks Jev whether work was left
// undone, except while a human or a delegated step is being waited on; a confident yes blocks the
// stop once per turn with a fixed reason. shouldConsult owns the route table; each scene below
// changes one thing from a consulting base scene and expects no query.
// TL3 gap: Claude Code honoring the block and resuming the turn. Mitigation: the real hook runs
// against real workflow state; only the Jev service is the loopback mock.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { after, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./feature-2461-jev/fixture");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2461cs-"));
const mock = F.startMock(path.join(ROOT, "mock"));
after(() => {
  mock.stop();
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const GUARD = "hooks/stop-premature-stop-guard.js";
const DELEGATED = ["research", "detail", "write_tests", "review_tests"];
const STEPS = require(F.lib("hooks/workflow-state/state-io/core.js")).VALID_STEPS;
const LATER = STEPS.slice(STEPS.indexOf("clarify_intent") + 1);
// Stopped with work announced; the Bash call keeps it from reading as a dialog turn.
const WORK = [F.U("go"), F.A(F.TU("Bash", { command: "ls" })), F.R(), F.A(F.T("Next I will edit report.js. MARKER-6603"))];
const DIALOG = [F.U("what does report.js do?"), F.A(F.T("It renders the summary table."))];
const YES = () => mock.conv(0.02, { "work-remaining": 0.97 });

// State seeders: each leaves the session where next-step reports the named action.
const SEED = {
  done: (sc, sid) => { F.seedStarted(sc, sid); F.markSteps(sc, sid, LATER.map((s) => [s, "skipped"])); },
  blocked: (sc, sid) => F.markSteps(sc, sid, [["workflow_init", "complete"]]),
  abort: (sc, sid) => { F.seedStarted(sc, sid); F.markSteps(sc, sid, [["branching_complete", "complete"]]); },
  invoke: (sc, sid) => F.seedStarted(sc, sid),
  delegatedReason: (sc, sid) => {
    F.seedStarted(sc, sid);
    F.markSteps(sc, sid, LATER.filter((s) => s !== "pre_final_report_gate" && s !== "final_report").map((s) => [s, "skipped"]));
  },
  none: () => {},
};
// scene(name, seed, entries) -> {sc, sid, tp}: a seeded session with one prompt turn.
function scene(name, seed, entries = WORK) {
  const sc = F.scene(ROOT, name);
  const sid = F.newSid();
  SEED[seed](sc, sid);
  const tp = F.writeTranscript(sc, "t", entries);
  F.promptTurn(sc, sid, tp);
  return { sc, sid, tp };
}
// stop(s, extra) -> {o, block (the decision JSON or null), q (systemone queries during the run)}.
function stop(s, extra = {}, input = {}) {
  const before = mock.count("systemone");
  const o = F.runHook(s.sc, mock, GUARD, Object.assign({ session_id: s.sid, hook_event_name: "Stop", stop_hook_active: false, transcript_path: s.tp, cwd: F.fwd(s.sc.cwd) }, input), extra);
  const block = o.json && o.json.decision === "block" ? o.json : null;
  return { o, block, q: mock.count("systemone") - before };
}
const action = (s) => F.nextStep(s.sc, null, s.sid, [], { JEV: "off" });
const inFlight = (s) => F.nodeEval(s.sc, null, `console.log(JSON.stringify({ s: require(${JSON.stringify(F.lib("hooks/workflow-state"))}).anyStepInFlight(process.argv[2]) }))`, [s.sid], { JEV: "off" }).json.s;
const contRecords = (s) => F.records(s.sc).filter((r) => r.point === "continuation");

caseBegin("should-consult-table", "hooks/lib/jev-continue-on-stop.js");
const ROUTES = [
  [{ sessionExemption: null, action: "done" }, true],
  [{ sessionExemption: null, action: "blocked" }, true],
  [{ sessionExemption: null, action: "abort" }, true],
  [{ sessionExemption: null, action: null }, true],
  [{ sessionExemption: "step-in-flight", inFlightStep: "write_code" }, true],
  [{ sessionExemption: null, action: "invoke", outputExemption: null }, false],
  ...["workflow-off", "next-step-paused", "pre-workflow-init"].map((e) => [{ sessionExemption: e, action: "done" }, false]),
  ...DELEGATED.map((st) => [{ sessionExemption: "step-in-flight", inFlightStep: st }, false]),
  ...["delegated-reason", "awaiting-plan-approval", "human-web-merge-wait", "user-dialog-turn", "jev-wait-on-invoke"]
    .map((e) => [{ sessionExemption: null, action: "invoke", outputExemption: e }, false]),
];
test("shouldConsult: Jev only where the stop would pass and nobody is being waited on", () => {
  const { shouldConsult } = require(F.lib("hooks/lib/jev-continue-on-stop.js"));
  for (const [args, want] of ROUTES) assert.strictEqual(!!shouldConsult(args), want, JSON.stringify(args));
});
caseEnd();

caseBegin("consult-routes-block", "hooks/lib/jev-continue-on-stop.js");
for (const seed of ["done", "blocked", "abort"]) {
  test(`ACTION=${seed}: one query, a confident yes blocks the stop with the fixed reason and a record`, () => {
    const s = scene(`route-${seed}`, seed);
    assert.strictEqual(action(s).kv("ACTION"), seed, "premise");
    YES();
    const r = stop(s);
    assert.strictEqual(r.q, 1, `one query (stderr ${r.o.stderr.slice(0, 300)})`);
    assert.ok(r.block, `blocked (stdout ${r.o.stdout.slice(0, 300)})`);
    assert.ok(typeof r.block.reason === "string" && r.block.reason.length > 0);
    assert.ok(!r.block.reason.includes("MARKER-6603"), "the reason never echoes the transcript");
    const rec = contRecords(s)[0];
    assert.ok(rec, "a continuation record");
    assert.deepStrictEqual(rec.judged_in, { kind: "hook", name: "stop-premature-stop-guard" });
    assert.strictEqual(rec.final.direction, "continue-on-stop");
    assert.strictEqual(rec.final.intervene, true);
  });
}
test("write_code in flight: Jev is asked without starting next-step, a confident yes blocks", () => {
  const s = scene("route-write-code", "invoke");
  F.markSteps(s.sc, s.sid, [["write_code", "in_progress"]]);
  assert.strictEqual(inFlight(s), "write_code", "premise");
  YES();
  const r = stop(s, F.spyEnv(s.sc));
  assert.strictEqual(r.q, 1);
  assert.ok(r.block, "blocked");
  assert.strictEqual(F.spyCalls(s.sc).filter((c) => c.args.length && F.fwd(c.args[0]).endsWith("bin/workflow/next-step")).length, 0, "next-step not started");
});
test("the reason is fixed: the same key on another transcript gives the same text", () => {
  const a = scene("fixed-a", "done");
  const b = scene("fixed-b", "done", [F.U("go"), F.A(F.TU("Bash", { command: "pwd" })), F.R(), F.A(F.T("Remaining: tests and docs."))]);
  YES();
  const ra = stop(a);
  YES();
  const rb = stop(b);
  assert.ok(ra.block && rb.block);
  assert.strictEqual(ra.block.reason, rb.block.reason);
});
// next-step failing: the fake replaces it in an ACTION=invoke session, so a working next-step would
// give the C4 block without a query; Jev's input is the transcript alone.
for (const [name, mode] of [["non-zero exit", "exit:3"], ["no output", "empty"], ["timeout", "hang:8000"]]) {
  test(`next-step ${name}: one query, a confident yes blocks with an intervening record`, () => {
    const s = scene(`route-ns-${mode.replace(/[^a-z]+/g, "-")}`, "invoke");
    YES();
    const r = stop(s, F.fakeNextStepEnv(mode));
    assert.strictEqual(r.q, 1, `one query (stderr ${r.o.stderr.slice(0, 300)})`);
    assert.ok(r.block, `blocked (stdout ${r.o.stdout.slice(0, 300)})`);
    assert.ok(!r.block.reason.includes("[C4 premature-stop]"), "the Jev block, not the C4 one");
    const rec = contRecords(s)[0];
    assert.ok(rec, "a continuation record");
    assert.strictEqual(rec.final.intervene, true);
  });
}
for (const [name, set] of [["below-threshold", () => mock.conv(0.85)], ["confident-no", () => mock.conv(0.02)], ["http500", () => mock.mode({ capture: true, systemone: "http:500" })]]) {
  test(`${name}: asked once, the stop passes`, () => {
    const s = scene(`pass-${name}`, "done");
    set();
    const r = stop(s);
    assert.strictEqual(r.q, 1);
    assert.strictEqual(r.block, null);
    assert.strictEqual(r.o.status, 0);
  });
}
caseEnd();

caseBegin("once-per-turn", "hooks/lib/jev-continue-on-stop.js");
test("second stop in the same turn: no query, no block; the next prompt turn re-arms it", () => {
  const s = scene("once", "done");
  YES();
  assert.ok(stop(s).block, "first stop blocked");
  assert.ok(F.readJson(F.controlFile(s.sc, s.sid, "continue-on-stop.json")), "continue-on-stop.json written");
  YES();
  const second = stop(s);
  assert.strictEqual(second.q, 0);
  assert.strictEqual(second.block, null);
  F.promptTurn(s.sc, s.sid, s.tp);
  YES();
  const third = stop(s);
  assert.strictEqual(third.q, 1);
  assert.ok(third.block, "a new turn blocks again");
});
test("corrupt continue-on-stop.json is treated as absent", () => {
  const s = scene("corrupt", "done");
  F.writeControl(s.sc, s.sid, "continue-on-stop.json", "{not json");
  YES();
  const r = stop(s);
  assert.strictEqual(r.q, 1);
  assert.ok(r.block);
});
caseEnd();

caseBegin("excluded-scenes", "hooks/lib/jev-continue-on-stop.js");
const stateDir = (s) => F.nodeEval(s.sc, null, `console.log(JSON.stringify({ d: require(${JSON.stringify(F.lib("hooks/workflow-state"))}).getSessionStateDir(process.argv[2]) }))`, [s.sid], { JEV: "off" }).json.d;
const EXCLUDED = [
  ["stop_hook_active", "done", null, { input: { stop_hook_active: true } }],
  ["JEV=off", "done", null, { extra: { JEV: "off" } }],
  ["pre-workflow-init (no workflow state)", "none", null, {}],
  ["workflow-off marker", "done", (s) => fs.writeFileSync(path.join(stateDir(s), `${s.sid}.workflow-off`), ""), {}],
  ["next-step paused", "done", (s) => F.nodeEval(s.sc, null, `process.exit(require(${JSON.stringify(F.lib("hooks/lib/next-step-pause-marker.js"))}).writePauseMarker(process.argv[2], { reason: "test pause" }) ? 0 : 1)`, [s.sid], { JEV: "off" }), {}],
  ["user-dialog-turn", "invoke", null, { entries: DIALOG }],
  ["delegated-reason (pre_final_report_gate)", "delegatedReason", (s) => assert.strictEqual(action(s).kv("REASON"), "'pre_final_report_gate'", "premise"), {}],
  ...DELEGATED.map((st) => [`${st} in flight`, "invoke", (s) => { F.markSteps(s.sc, s.sid, [[st, "in_progress"]]); assert.strictEqual(inFlight(s), st, "premise"); }, {}]),
  ["research and write_code both in flight", "invoke", (s) => { F.markSteps(s.sc, s.sid, [["research", "in_progress"], ["write_code", "in_progress"]]); assert.strictEqual(inFlight(s), "research", "premise"); }, {}],
  // Neither wait can be seeded through real state from a hook run (a presentation turn / a live
  // merge poller), so the fake next-step prints the exact lines approval-reason.js / release-wait.js emit.
  ["awaiting-plan-approval", "invoke", null, { passes: true, extra: F.fakeNextStepEnv("stdout:ACTION=invoke\\nNEXT_SKILL=make-outline-plan\\nREASON='awaiting-plan-approval: make_outline_plan'\\n") }],
  ["human-web-merge-wait", "invoke", null, { passes: true, extra: F.fakeNextStepEnv("stdout:ACTION=invoke\\nNEXT_SKILL=merge-to-main\\nWAIT=human-web-merge\\n") }],
];
for (const [name, seed, prep, opt] of EXCLUDED) {
  test(`${name}: Jev is not asked`, () => {
    const s = scene(`ex-${name.replace(/[^a-z]+/gi, "-")}`, seed, opt.entries || WORK);
    if (prep) prep(s);
    YES();
    const r = stop(s, opt.extra || {}, opt.input || {});
    assert.strictEqual(r.q, 0, `no query (stdout ${r.o.stdout.slice(0, 200)})`);
    assert.ok(!r.block || !/jev|continue-on-stop/i.test(r.block.reason), "no Jev block");
    if (opt.passes) assert.strictEqual(r.block, null, "the wait lets the stop pass (the fake output took effect)");
    assert.deepStrictEqual(contRecords(s), []);
  });
}
test("ACTION=invoke with no exemption: the existing C4 block, Jev not asked", () => {
  const s = scene("ex-invoke", "invoke");
  YES();
  const r = stop(s);
  assert.strictEqual(r.q, 0);
  assert.ok(r.block && r.block.reason.includes("[C4 premature-stop]"));
});
test("jev-wait-on-invoke advised this turn: the stop passes and Jev is not asked again", () => {
  const s = scene("ex-wait", "invoke");
  mock.conv(0.02, { "asked-user": 0.97 });
  assert.strictEqual(F.nextStep(s.sc, mock, s.sid).kv("JEV_ADVICE"), "wait-on-invoke", "premise: advised this turn");
  YES();
  const r = stop(s);
  assert.strictEqual(r.q, 0);
  assert.strictEqual(r.block, null, `the stop passes (stdout ${r.o.stdout.slice(0, 200)})`);
});
test("jev-wait-on-invoke advised this turn, then write_code in flight: Jev is not asked", () => {
  const s = scene("ex-wait-wc", "invoke");
  mock.conv(0.02, { "asked-user": 0.97 });
  assert.strictEqual(F.nextStep(s.sc, mock, s.sid).kv("JEV_ADVICE"), "wait-on-invoke", "premise: advised this turn");
  F.markSteps(s.sc, s.sid, [["write_code", "in_progress"]]);
  assert.strictEqual(inFlight(s), "write_code", "premise");
  YES();
  const r = stop(s);
  assert.strictEqual(r.q, 0);
  assert.strictEqual(r.block, null);
  assert.deepStrictEqual(contRecords(s).filter((x) => x.judged_in && x.judged_in.kind === "hook"), []);
});
caseEnd();

caseBegin("exemption-rows", "hooks/lib/stop-exemption-policy.js");
test("jev-wait-on-invoke: a next-step-output C4 row and a c4 EXEMPTION_MATRIX row; the guard stays within WARN", () => {
  const { EXEMPTION_MATRIX } = require(F.lib("hooks/lib/stop-exemption-policy.js"));
  const { C4_EXEMPTIONS } = require(F.lib(GUARD));
  const row = C4_EXEMPTIONS.find((e) => e.id === "jev-wait-on-invoke");
  assert.ok(row, "C4_EXEMPTIONS row");
  assert.strictEqual(row.phase, "next-step-output");
  assert.ok(EXEMPTION_MATRIX["jev-wait-on-invoke"], "EXEMPTION_MATRIX row");
  assert.strictEqual(EXEMPTION_MATRIX["jev-wait-on-invoke"].c4, true);
  for (const e of C4_EXEMPTIONS) assert.strictEqual((EXEMPTION_MATRIX[e.id] || {}).c4, true, `${e.id} has a c4 matrix row`);
  const lines = fs.readFileSync(path.join(F.REPO, GUARD), "utf8").split("\n").length - 1;
  assert.ok(lines <= 300, `${GUARD} is ${lines} lines`);
});
caseEnd();
