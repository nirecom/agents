#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/reset-allowance.js, hooks/workflow-state/reset-allowance/forward.js, hooks/workflow-state/reset-allowance/replay.js, hooks/workflow-state/reset-allowance/decide.js, hooks/workflow-state/reset-allowance/reason-block.js
// Tags: TL2, reset-allowance, reset-from, confirm-gate, workflow-state, scope:issue-specific, pwsh-not-required
// #2852: decideReset answers allow / ask for one RESET_FROM_<target> by replaying the reset events against an
// allowance of 2 (rules: the detail plan section on judging if a past reset hit a later step; the replay table).
// Covered: spend / refill per phase, CONFIRM_* boundary, later target, forward and unpinned-profile
// replay, unreadable input. Nothing here writes.
// TL3 gap (what this test does NOT catch):
// - the flag read count per decision (one read per flag) — not observable from the result.
// - decision time: the checkpoint hook into checkDecisionTime is covered by feature-2852-reset-from-gate.js.

// lang-check: ignore — fixtures carry Japanese reset reasons to verify the reason block renders them.
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { confirmEnvRoot, withConfirmEnv } = require("../lib/confirm-env-fixture");

const restore = isolate();
const BASE = fs.mkdtempSync(path.join(os.tmpdir(), "f2852a-"));
const REPO = path.join(BASE, "repo");
fs.mkdirSync(REPO);
gitInit(REPO);
after(() => {
  restore();
  fs.rmSync(BASE, { recursive: true, force: true });
});

const F = require("./feature-2852-reset-allowance/fixture");
const ENTRY = "hooks/workflow-state/reset-allowance.js";
const DIR = "hooks/workflow-state/reset-allowance";

let n = 0;
const newSid = (tag) => `f2852-${tag}-${++n}`;

// decideWith(state, sid, target, flags) — one decision with the CONFIRM_* flags fixed by a .env.
function decideWith(state, sid, target, flags) {
  const decideReset = F.need(ENTRY, "decideReset");
  const cfg = confirmEnvRoot(BASE, flags || F.ALL_OFF);
  const r = withConfirmEnv(cfg, () => decideReset({ state, sid, target, reason: "fixture decision", repoDir: REPO }));
  assert.ok(r && (r.decision === "allow" || r.decision === "ask"), `decision: ${JSON.stringify(r)}`);
  return r;
}

// decide(target, events, opts) — seeds a fresh session and decides one reset on it.
function decide(target, events, opts) {
  const o = opts || {};
  const sid = newSid(o.tag || "d");
  F.seed(sid, events, { deliveryPath: o.deliveryPath, cwd: REPO });
  return decideWith(F.read(sid), sid, target, o.flags);
}

function expectAsk(r, label) {
  assert.strictEqual(r.decision, "ask", `${label}: ${JSON.stringify(r)}`);
  assert.ok(typeof r.why === "string" && r.why !== "", `${label}: ask carries a why: ${JSON.stringify(r)}`);
}
const expectAllow = (r, label) => assert.strictEqual(r.decision, "allow", `${label}: ${JSON.stringify(r)}`);
const outcomes = (r) => ((r.replay && r.replay.rows) || []).map((row) => row.outcome);

const CUR = "review_security";
const W = "write_code";
const O = "outline";
const C = "clarify_intent";

caseBegin("entry-reexports", "hooks/workflow-state/reset-allowance.js");
test("the entry re-exports decideReset and isForwardAt from their own modules", () => {
  const entry = F.need(ENTRY);
  assert.strictEqual(entry.decideReset, F.need(`${DIR}/decide.js`, "decideReset"));
  assert.strictEqual(entry.isForwardAt, F.need(`${DIR}/forward.js`, "isForwardAt"));
});
caseEnd();

caseBegin("implementation-allowance", "hooks/workflow-state/reset-allowance/decide.js");
test("flags off: resets to an implementation step pass twice, the third asks", () => {
  expectAllow(decide(W, F.history(CUR, [])), "1st");
  expectAllow(decide(W, F.history(CUR, [W])), "2nd");
  const third = decide(W, F.history(CUR, [W, W]));
  expectAsk(third, "3rd");
  assert.notStrictEqual(third.why, "no-current-step");
});
test("an approved implementation reset does not refill the allowance", () => {
  const r = decide(W, F.history(CUR, [W, W, W]));
  expectAsk(r, "4th after an approved 3rd");
  assert.strictEqual(r.replay.allowance, 0);
  assert.deepStrictEqual(outcomes(r).slice(0, 2), ["passed", "passed"]);
  assert.notStrictEqual(outcomes(r)[2], "passed");
});
test("an implementation target ignores the CONFIRM_* flags", () => {
  const on = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" };
  expectAllow(decide(W, F.history(CUR, []), { flags: on }), "flags on, 1st");
});
caseEnd();

caseBegin("pre-implementation-allowance", "hooks/workflow-state/reset-allowance/decide.js");
test("flags off: resets to a pre-implementation step pass twice, the third asks", () => {
  expectAllow(decide(O, F.history(CUR, [])), "1st (reads row.confirmFlag)");
  expectAllow(decide(O, F.history(CUR, [O])), "2nd");
  expectAsk(decide(O, F.history(CUR, [O, O])), "3rd");
});
test("an approved pre-implementation reset refills the allowance to 2", () => {
  const r = decide(O, F.history(CUR, [O, O, O]));
  expectAllow(r, "4th after an approved 3rd");
  assert.strictEqual(r.replay.allowance, 2);
  assert.deepStrictEqual(outcomes(r).slice(0, 2), ["passed", "passed"]);
  assert.notStrictEqual(outcomes(r)[2], "passed");
});
test("a past pre-implementation reset under a flag that is not off counts as approved (refill)", () => {
  // CONFIRM_INTENT on: the reset to clarify_intent was asked, so it refills 2 between the two
  // outline passes; the fourth reset to outline still passes.
  const flags = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "off", CONFIRM_DETAIL: "off" };
  const r = decide(O, F.history(CUR, [O, C, O]), { flags });
  expectAllow(r, "outline after outline, clarify_intent (asked), outline");
  assert.deepStrictEqual(outcomes(r)[0], "passed");
  assert.notStrictEqual(outcomes(r)[1], "passed");
  assert.deepStrictEqual(outcomes(r)[2], "passed");
});
caseEnd();

caseBegin("confirm-flag-boundary", "hooks/workflow-state/reset-allowance/decide.js");
const flagCases = [
  ["outline / CONFIRM_OUTLINE=on", O, { CONFIRM_OUTLINE: "on" }, "ask"],
  ["outline / CONFIRM_OUTLINE=bogus (unrecognized)", O, { CONFIRM_OUTLINE: "bogus" }, "ask"],
  ["outline / CONFIRM_OUTLINE unset", O, { CONFIRM_OUTLINE: null }, "ask"],
  ["outline / CONFIRM_DETAIL=on (a row after the target)", O, { CONFIRM_DETAIL: "on" }, "ask"],
  ["detail / CONFIRM_OUTLINE=on (a row before the target)", "detail", { CONFIRM_OUTLINE: "on" }, "allow"],
  ["detail / CONFIRM_DETAIL=on", "detail", { CONFIRM_DETAIL: "on" }, "ask"],
  ["detail / CONFIRM_INTENT=on (a row before the target)", "detail", { CONFIRM_INTENT: "on" }, "allow"],
];
for (const [label, target, over, want] of flagCases) {
  test(`flag boundary: ${label} -> ${want}`, () => {
    const r = decide(target, F.history(CUR, []), { flags: Object.assign({}, F.ALL_OFF, over) });
    if (want === "ask") expectAsk(r, label); else expectAllow(r, label);
  });
}
caseEnd();

caseBegin("clarify-intent-reads-confirm-intent", "hooks/workflow-state/reset-allowance/decide.js");
test("a reset to clarify_intent reads CONFIRM_INTENT", () => {
  const intentOn = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "off", CONFIRM_DETAIL: "off" };
  expectAsk(decide(C, F.history(CUR, []), { flags: intentOn }), "clarify_intent, CONFIRM_INTENT=on");
  expectAllow(decide(O, F.history(CUR, []), { flags: intentOn }), "outline, CONFIRM_INTENT=on");
  expectAllow(decide(C, F.history(CUR, []), { flags: F.ALL_OFF }), "clarify_intent, all off");
  expectAsk(decide(C, F.history(CUR, []), { flags: Object.assign({}, F.ALL_OFF, { CONFIRM_INTENT: "bogus" }) }), "clarify_intent, CONFIRM_INTENT=bogus");
});
caseEnd();

// write_code resume: run_tests failed after write_code completed, so write_code reads pending again
// (a derived reopen the raw projection does not show) and run_tests is not settled.
const resumeEvents = (outcome) => F.completeRange("workflow_init", "run_tests")
  .concat([F.note("run_tests", "run_outcome", outcome), F.st("run_tests", "pending")]);

caseBegin("later-target-always-asks", "hooks/workflow-state/reset-allowance/decide.js");
test("write_code resume: RESET_FROM_run_tests asks with the allowance full", () => {
  const r = decide("run_tests", resumeEvents("fail"));
  expectAsk(r, "run_tests after the resume");
  assert.notStrictEqual(r.why, "no-current-step");
  expectAsk(decide(CUR, resumeEvents("fail")), "review_security after the resume");
  expectAllow(decide(W, resumeEvents("fail")), "control: write_code itself");
});
test("a reset past the current step asks", () => {
  expectAsk(decide("docs", F.history(CUR, [])), "docs while at review_security");
  expectAsk(decide("final_report", F.history(CUR, [])), "final_report while at review_security");
});
caseEnd();

caseBegin("no-current-step", "hooks/workflow-state/reset-allowance/decide.js");
test("every step settled -> ask with why no-current-step", () => {
  const r = decide(W, F.completeRange("workflow_init", "final_report"));
  assert.strictEqual(r.decision, "ask", JSON.stringify(r));
  assert.strictEqual(r.why, "no-current-step");
});
caseEnd();

caseBegin("replay-forward-as-approved", "hooks/workflow-state/reset-allowance/replay.js");
test("a past reset to a later step replays as approved and spends nothing", () => {
  // At the first reset the session stood at review_tests (branching_complete settled), so
  // RESET_FROM_write_code went forward (it was asked). Only the second reset spends.
  const events = F.completeRange("workflow_init", "review_tests")
    .concat(F.resetEvents(W, "forward"), F.resetEvents(W, "back"));
  const r = decide(W, events);
  expectAllow(r, "third reset to write_code");
  assert.strictEqual(r.replay.allowance, 1);
  assert.notStrictEqual(outcomes(r)[0], "passed");
  assert.strictEqual(outcomes(r)[1], "passed");
});
test("boundary (a): a later-step reset while branching_complete was unsettled is not approved", () => {
  // The profile is not pinned before branching_complete settles, so the first reset (standing
  // at branching_complete) does not replay as forward: both resets spend and the third asks.
  const events = F.completeRange("workflow_init", "branching_complete")
    .concat(F.resetEvents(W, "unpinned"), F.resetEvents(W, "back"));
  const r = decide(W, events);
  expectAsk(r, "third reset to write_code");
  assert.strictEqual(r.replay.allowance, 0);
  assert.deepStrictEqual(outcomes(r), ["passed", "passed"]);
});
test("boundary (b) control: a forward reset after the un-pinning reset still replays as approved", () => {
  // Reset to branching_complete un-pins the profile (spends one); the profile is pinned again
  // when branching_complete re-completes; the forward reset after that is approved.
  const events = F.completeRange("workflow_init", "cleanup")
    .concat(F.resetEvents("branching_complete", "unpin"), F.completeRange("branching_complete", "review_tests"),
      F.resetEvents(W, "forward"), F.completeRange(W, CUR));
  const r = decide(W, events);
  expectAllow(r, "third reset");
  assert.strictEqual(r.replay.allowance, 1);
  assert.strictEqual(outcomes(r)[0], "passed");
  assert.notStrictEqual(outcomes(r)[1], "passed");
});
caseEnd();

caseBegin("evidence-only-prefix-is-not-forward", "hooks/workflow-state/reset-allowance/forward.js");
// forwardAt(events, target, path) — isForwardAt over the projected prefix state, under the given delivery path.
function forwardAt(events, target, deliveryPath) {
  const isForwardAt = F.need(ENTRY, "isForwardAt");
  const sid = newSid("fw");
  F.seed(sid, events, { deliveryPath, cwd: REPO });
  const state = F.read(sid);
  assert.ok(state, "fixture: prefix state reads");
  const profile = F.mod("hooks/workflow-state/session-profile").resolveSessionProfile(state, sid, { repoDir: REPO });
  return isForwardAt(state, target, profile);
}
const allBut = (...pending) => F.completeRange("workflow_init", "final_report").concat(pending.map((s) => F.st(s, "pending")));
test("only an evidence step (detail / write_tests / docs) unsettled -> not forward", () => {
  assert.strictEqual(forwardAt(allBut("detail"), W), false, "detail");
  assert.strictEqual(forwardAt(allBut("write_tests"), W), false, "write_tests");
  assert.strictEqual(forwardAt(allBut("docs"), "review_docs"), false, "docs");
});
test("only a network evidence step (push_branch) unsettled -> not forward", () => {
  assert.strictEqual(forwardAt(allBut("push_branch"), "user_verification"), false);
});
test("control: a non-evidence step (review_tests) unsettled -> forward", () => {
  // Not branching_complete: an unsettled branching_complete is excluded by the replay rule for
  // an unpinned profile, and the plan leaves open whether isForwardAt or replay applies it.
  assert.strictEqual(forwardAt(allBut("review_tests"), W), true);
});
test("table-skip follows the profile: cleanup pending is forward on pull_request only", () => {
  assert.strictEqual(forwardAt(allBut("cleanup"), "pre_final_report_gate", "direct"), false, "direct");
  assert.strictEqual(forwardAt(allBut("cleanup"), "pre_final_report_gate", "pull_request"), true, "pull_request");
});
test("a delivery-boundary pending (branching_complete post-push, merge settled) -> not forward", () => {
  const settled = allBut("branching_complete").concat([F.note("branching_complete", "reset_reason", "post-push")]);
  assert.strictEqual(forwardAt(settled, "write_tests"), false, "merge_to_main settled");
  // merge_to_main pending leaves branching_complete unsettled: not asserted here, see control.
});
test("replay: a past reset while only detail was unsettled spends the allowance", () => {
  // The first reset happened with detail pending (an evidence step), so it replays as passed.
  const events = F.completeRange("workflow_init", "detail")
    .concat(F.completeRange("branching_complete", CUR), F.resetEvents(W, "r1"), [F.approval("detail")],
      F.completeRange(W, CUR), F.resetEvents(W, "r2"), F.completeRange(W, CUR));
  const r = decide(W, events);
  expectAsk(r, "third reset to write_code");
  assert.deepStrictEqual(outcomes(r), ["passed", "passed"]);
});
caseEnd();

caseBegin("unknown-step-asks", "hooks/workflow-state/reset-allowance/decide.js");
test("an unknown target asks", () => {
  for (const target of ["bogus_step", "", "WRITE_CODE"]) expectAsk(decide(target, F.history(CUR, [])), JSON.stringify(target));
});
// A past reset with an unclassifiable from_step is not built here: events.js validateEvent
// rejects a from_step outside VALID_STEPS, so the stream cannot hold one.
caseEnd();

caseBegin("corrupt-state-asks", "hooks/workflow-state/reset-allowance/decide.js");
test("a missing, malformed or unreadable state asks and never throws", () => {
  const sid = newSid("bad");
  const shapes = [
    ["null", null],
    ["no events", { session_id: sid, steps: {} }],
    ["events not an array", { session_id: sid, steps: {}, events: "x" }],
    ["event with a seq gap", { session_id: sid, steps: {}, events: [{ seq: 5, kind: "step_status", step: "workflow_init", status: "complete", provenance: "declared", origin: "x" }] }],
  ];
  for (const [label, state] of shapes) expectAsk(decideWith(state, sid, W), label);
});
test("a state file that is not JSON reads as null and asks", () => {
  const sid = newSid("json");
  fs.writeFileSync(F.statePath(sid), "{ not json", "utf8");
  expectAsk(decideWith(F.read(sid), sid, W), "invalid JSON");
});
caseEnd();

caseBegin("replay-rows-are-reset-events", "hooks/workflow-state/reset-allowance/replay.js");
test("replay rows list the reset events only, never an automatic reopen", () => {
  // A write_code reopen of review_tests and a failing run_tests are reopens, not resets.
  const events = F.history(CUR, [W]).concat([
    F.note("review_tests", "reopen_reason", "write-code-reopen"), F.st("review_tests", "pending", "write-code-reopen"),
  ], F.completeRange("review_tests", CUR), F.history(CUR, [W]).slice(F.completeRange("workflow_init", CUR).length));
  const sid = newSid("rows");
  F.seed(sid, events, { cwd: REPO });
  const r = decideWith(F.read(sid), sid, W);
  const resetSeqs = F.raw(sid).events.filter((e) => e.kind === "reset").map((e) => e.seq);
  assert.strictEqual(resetSeqs.length, 2, "fixture: two resets");
  assert.deepStrictEqual(r.replay.rows.map((row) => row.seq), resetSeqs);
  for (const row of r.replay.rows) {
    assert.strictEqual(row.from_step, W);
    assert.ok(typeof row.reason === "string" && row.reason !== "", JSON.stringify(row));
    assert.ok(typeof row.at === "string", JSON.stringify(row));
    assert.ok(["passed", "approved", "ask"].includes(row.outcome), JSON.stringify(row));
  }
});
caseEnd();

caseBegin("reason-block-module", "hooks/workflow-state/reset-allowance/reason-block.js");
test("reason-block.js loads and exports its builder", () => {
  // The builder's name is not fixed by the plan; its text is checked through the hook's ask
  // reason in feature-2852-reset-from-gate.js.
  const m = F.need(`${DIR}/reason-block.js`);
  assert.ok(Object.values(m).some((v) => typeof v === "function"), `exports: ${Object.keys(m)}`);
});
caseEnd();

caseBegin("cycle-boundary-keeps-counting", "hooks/workflow-state/reset-allowance/replay.js");
test("resets before a cycle_boundary still count", () => {
  const r = decide(W, F.history(CUR, [W, F.cycleBoundary(1), W]));
  expectAsk(r, "third reset across a cycle boundary");
  assert.strictEqual(r.replay.rows.length, 2);
});
caseEnd();

caseBegin("profile-unpin-excludes-earlier-resets", "hooks/workflow-state/reset-allowance/replay.js");
test("audit WARN(1): resets before an un-pinning reset never replay as approved", () => {
  // The real path of a profile change: two resets to pre_final_report_gate on direct (cleanup
  // table-skipped, never recorded), then RESET_FROM_branching_complete un-pins the profile
  // (clearDeliveryProfile) and the re-completion pins pull_request. Read under pull_request the
  // first prefix shows cleanup owed, but a later reset to branching_complete or earlier exists,
  // so it is not approved: p1 and p2 spend 2, the un-pin finds 0 and is approved (impl: no
  // refill), and the next reset asks with 0 left.
  const T = "pre_final_report_gate";
  const events = F.completeRange("workflow_init", "cleanup")
    .concat(F.resetEvents(T, "p1"), F.resetEvents(T, "p2"),
      F.resetEvents("branching_complete", "unpin"), F.completeRange("branching_complete", T));
  const sid = newSid("prof");
  F.seed(sid, events, { deliveryPath: "pull_request", cwd: REPO });
  const r = decideWith(F.read(sid), sid, T);
  expectAsk(r, "fourth reset after the re-pin");
  assert.strictEqual(r.replay.allowance, 0);
  assert.deepStrictEqual(outcomes(r).slice(0, 2), ["passed", "passed"]);
  assert.notStrictEqual(outcomes(r)[2], "passed");
});
caseEnd();

// review_security F2 (MEDIUM): askReason shows the reason and the replayed rows; a control
// character must not forge a line, and a long value must not flood the approval block.
const askReasonFn = () => F.need(`${DIR}/reason-block.js`, "askReason");
const row = (over) => Object.assign({ seq: 7, at: "2026-01-01T00:00:00.000Z", from_step: W, outcome: "passed", reason: "plain row" }, over);
const askResult = (rows) => ({ why: "allowance-spent", replay: { allowance: 0, rows } });
const lineCount = (text) => text.split("\n").length;
const CTRL = /[\x00-\x09\x0b-\x1f\x7f]/;
const FORGED = /^(?:allowance left|why|reset count): 9\d/m;
caseBegin("reason-block-control-characters", "hooks/workflow-state/reset-allowance/reason-block.js");
const ctrlCases = [
  { name: "reason with LF", reason: "a\nallowance left: 99", rows: [row()] },
  { name: "reason with CR, TAB, BEL and DEL", reason: "a\rallowance left: 99\tb\x07c\x7fd", rows: [row()] },
  { name: "row.reason with LF", reason: "plain", rows: [row({ reason: "x\nallowance left: 98" })] },
  { name: "row.at with LF", reason: "plain", rows: [row({ at: "2026\nallowance left: 97" })] },
  { name: "row.seq with LF", reason: "plain", rows: [row({ seq: "7\nwhy: 96" })] },
];
for (const { name, reason, rows } of ctrlCases) {
  test(`askReason: ${name} adds no line and leaves no control character`, () => {
    const askReason = askReasonFn();
    const baseline = askReason(W, "plain", askResult(rows.map(() => row())));
    const out = askReason(W, reason, askResult(rows));
    assert.strictEqual(lineCount(out), lineCount(baseline), `${name}: line count: ${JSON.stringify(out)}`);
    assert.ok(!CTRL.test(out), `${name}: control character left: ${JSON.stringify(out)}`);
    assert.ok(!FORGED.test(out), `${name}: forged line: ${JSON.stringify(out)}`);
  });
}
caseEnd();

caseBegin("ask-reason-length-cap", "hooks/workflow-state/reset-allowance/reason-block.js");
const capCases = [
  { name: "reason", ch: "Q", reason: () => "Q".repeat(1000), rows: () => [row()] },
  { name: "row.reason", ch: "Z", reason: () => "plain", rows: () => [row({ reason: "Z".repeat(1000) })] },
  { name: "row.at", ch: "T", reason: () => "plain", rows: () => [row({ at: "T".repeat(1000) })] },
];
for (const { name, ch, reason, rows } of capCases) {
  test(`askReason: a 1000-character ${name} is cut, its head is kept`, () => {
    const out = askReasonFn()(W, reason(), askResult(rows()));
    assert.ok(!out.includes(ch.repeat(1000)), `${name}: shown whole (${out.length} chars)`);
    assert.ok(!out.includes(ch.repeat(201)), `${name}: more than 200 characters shown`);
    assert.ok(out.includes(ch.repeat(50)), `${name}: head dropped: ${out.slice(0, 120)}`);
  });
}
caseEnd();

caseBegin("reason-block-plain-text-kept", "hooks/workflow-state/reset-allowance/reason-block.js");
test("control: a plain reason and plain rows are shown as written", () => {
  const reason = "再実行: テスト失敗 (2回目, review)";
  const rows = [row({ seq: 3, at: "2026-01-01T00:03:00.000Z", reason: "前回の reset 理由" })];
  const out = askReasonFn()(W, reason, askResult(rows));
  for (const want of [reason, "前回の reset 理由", "2026-01-01T00:03:00.000Z", "#3", "allowance left: 0", "why: allowance-spent"]) {
    assert.ok(out.includes(want), `missing ${JSON.stringify(want)}: ${out}`);
  }
});
caseEnd();

// review_security F3 (LOW): an internal error asks with a short code; the message (it may hold
// an absolute path) is not part of why.
caseBegin("decide-error-message-hidden", "hooks/workflow-state/reset-allowance/decide.js");
test("an exception inside decideReset asks without its message", () => {
  const decideReset = F.need(ENTRY, "decideReset");
  const sid = newSid("err");
  F.seed(sid, F.history(CUR, []), { cwd: REPO });
  const secret = "C:/Users/someone/secret-dir/marker-f3-2852.js";
  let thrown = false;
  const checkpoint = () => { thrown = true; throw new Error(`${secret}: boom\nsecond line`); };
  const cfg = confirmEnvRoot(BASE, F.ALL_OFF);
  const r = withConfirmEnv(cfg, () => decideReset({ state: F.read(sid), sid, target: W, reason: "x", repoDir: REPO, checkpoint }));
  assert.ok(thrown, "fixture: the checkpoint never ran, so no exception was raised");
  expectAsk(r, "checkpoint throws");
  for (const leak of [secret, "marker-f3-2852", "boom"]) assert.ok(!r.why.includes(leak), `why leaks "${leak}": ${r.why}`);
});
test("control: the fixed why codes are unchanged", () => {
  const decideReset = F.need(ENTRY, "decideReset");
  assert.strictEqual(decideReset({ state: null, sid: "x", target: W }).why, "state-unreadable");
  assert.strictEqual(decide(W, F.completeRange("workflow_init", "final_report")).why, "no-current-step");
});
caseEnd();
