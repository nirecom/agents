"use strict";
// Tests: hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js, hooks/lib/stop-exemption-policy.js
// Tags: TL2, hooks, stop-hook, c4, c2, supervisor-guard, exemption, user-dialog-turn, premature-stop, mechanism-failure, scope:issue-specific, ask-user-question, system-message-contract, workflow-abort, regression-2920
// #2698 change 1: the real C4 Stop hook stays silent (no block, no finding) when the turn ends
// a dialog with the user, while the same session blocks for a non-dialog turn and for no
// transcript; the mechanism-failure lane still blocks on a stall. The real C2 supervisor-guard
// with the alert armed is silent for a dialog turn and blocks otherwise.
// TL3 gap (what this test does NOT catch):
// - a live Claude Code session writing the transcript and honouring the decision:block payload
// Closest-to-action mitigation: both hooks run as real child processes on a Stop stdin payload.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const { after, test } = require("node:test");
const X = require("./feature-2698-supervisor/fixture");

const restore = isolate();
process.env.CONV_LANG = "english";
const ROOT = X.tmpRoot("c4");
after(() => { restore(); X.rmRoot(ROOT); });

const C4 = "hooks/stop-premature-stop-guard.js";
const C2 = "hooks/supervisor-guard.js";
let n = 0;
function started(tag) {
  const dir = X.sceneDir(ROOT, `${tag}-${++n}`);
  const sid = `c4${tag}${n}`;
  X.seedStarted(dir, sid);
  return { dir, sid };
}
const findingsOf = (dir, sid) => {
  const st = X.readSup(dir, sid);
  return st && st.layer1 ? st.layer1.findings : [];
};
// A user question followed by a write tool in the same turn is work, not dialog — even when the
// final text also ends with a question, so the tool alone is what decides.
const WRITE_AFTER_QUESTION = (tool) => [X.U("Why does it fail?"), X.A(X.TU(tool, { file_path: "a.js", command: "ls" })), X.R(),
  X.A(X.T("I fixed a.js. Which file should I look at next?"))];
// Questions asked in plain text: an English one and a Japanese one (\u-escaped and decoded by
// JSON.parse, so no CJK sits in this source).
const QUESTIONS = {
  english: "Which file should I look at next?",
  japanese: JSON.parse('"\\u6b21\\u306f\\u3069\\u306e\\u30d5\\u30a1\\u30a4\\u30eb\\u3092\\u898b\\u307e\\u3059\\u304b\\uff1f"'),
};
const TEXT_QUESTION_TURNS = {
  "a Write in the turn": (q) => [X.U("Look into it.", { origin: { kind: "human" } }),
    X.A(X.TU("Write", { file_path: "a.js" })), X.R(), X.A(X.T(q))],
  "a task-notification opener": (q) => [X.U("<task-notification>run done</task-notification>", { origin: { kind: "task-notification" } }),
    X.A(X.TU("Read")), X.R(), X.A(X.T(q))],
};
const AUQ_END = () => [X.U("Look into it."), X.A(X.T("Which option?"), X.TU("AskUserQuestion", { questions: [] }))];
const AUQ_GUIDANCE = "If this turn is waiting on a user decision, ask it with the AskUserQuestion tool instead of plain text.";
// assertC4Blocked — rc 2 + [C4 premature-stop] + the warning/workflow finding + the alert armed.
function assertC4Blocked(dir, sid, r) {
  assert.strictEqual(r.status, 2, `rc 2 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.ok(r.json && r.json.decision === "block" && /\[C4 premature-stop\]/.test(r.json.reason), `C4 block (got ${r.stdout})`);
  const st = X.readSup(dir, sid);
  const list = (st && st.layer1 && st.layer1.findings) || [];
  const f = list.find((x) => x.reporter === "stop-premature-stop-guard");
  assert.ok(f, `a stop-premature-stop-guard finding is recorded (got ${JSON.stringify(list)})`);
  assert.strictEqual(f.severity, "warning");
  assert.ok(Array.isArray(f.categories) && f.categories.includes("workflow"), "category workflow");
  assert.match(f.detail, /^premature-stop: ACTION=invoke ignored/);
  assert.strictEqual(typeof (st.alert && st.alert.alert_armed_at), "string", "the alert is scheduled (alert_armed_at set)");
}

caseBegin("c4-dialog-turn-is-silent", "hooks/stop-premature-stop-guard.js");
test("control: a non-dialog transcript blocks with [C4 premature-stop], records the finding, arms the alert", () => {
  const { dir, sid } = started("ctl");
  const r = X.runHook(C4, dir, X.stopInput(dir, sid, X.NON_DIALOG()));
  assertC4Blocked(dir, sid, r);
});
for (const tool of ["Edit", "Write", "Bash"]) {
  test(`a user question followed by ${tool} in the turn is not exempt: block + finding + alert armed`, () => {
    const { dir, sid } = started(`w${tool}`);
    const r = X.runHook(C4, dir, X.stopInput(dir, sid, WRITE_AFTER_QUESTION(tool)));
    assertC4Blocked(dir, sid, r);
  });
}
test("no transcript at all still blocks (undecidable is not dialog)", () => {
  const { dir, sid } = started("none");
  const r = X.runHook(C4, dir, X.stopInput(dir, sid, null));
  assert.strictEqual(r.status, 2, `rc 2 (stdout: ${r.stdout})`);
});
test("dialog transcript: exit 0, no output, no finding recorded", () => {
  const { dir, sid } = started("dlg");
  const r = X.runHook(C4, dir, X.stopInput(dir, sid, X.DIALOG()));
  assert.strictEqual(r.status, 0, `rc 0 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.strictEqual(r.stdout.trim(), "", "no decision payload");
  assert.deepStrictEqual(findingsOf(dir, sid), [], "no premature-stop finding");
});
test("the same session blocks again once a non-dialog turn ends", () => {
  const { dir, sid } = started("seq");
  assert.strictEqual(X.runHook(C4, dir, X.stopInput(dir, sid, X.DIALOG(), "a")).status, 0);
  const r = X.runHook(C4, dir, X.stopInput(dir, sid, X.NON_DIALOG(), "b"));
  assert.strictEqual(r.status, 2, `rc 2 (stdout: ${r.stdout})`);
});
caseEnd();

caseBegin("c4-text-question-is-not-exempt", "hooks/stop-premature-stop-guard.js");
for (const [shape, build] of Object.entries(TEXT_QUESTION_TURNS)) {
  for (const [lang, q] of Object.entries(QUESTIONS)) {
    test(`a plain-text ${lang} question with ${shape}: block + finding + alert armed`, () => {
      const { dir, sid } = started(`tq${lang}${shape.length}`);
      const r = X.runHook(C4, dir, X.stopInput(dir, sid, build(q)));
      assertC4Blocked(dir, sid, r);
    });
  }
}
caseEnd();

caseBegin("c4-askuserquestion-end-is-silent", "hooks/stop-premature-stop-guard.js");
test("a turn ending in AskUserQuestion: exit 0, no output, no finding", () => {
  const { dir, sid } = started("auq");
  const r = X.runHook(C4, dir, X.stopInput(dir, sid, AUQ_END()));
  assert.strictEqual(r.status, 0, `rc 0 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.strictEqual(r.stdout.trim(), "", "no decision payload");
  assert.deepStrictEqual(findingsOf(dir, sid), [], "no premature-stop finding");
});
caseEnd();

caseBegin("c4-block-reason-askuserquestion-guidance", "hooks/stop-premature-stop-guard.js");
test("the C4 premature-stop block reason tells the model to ask decisions with AskUserQuestion", () => {
  const { dir, sid } = started("guide");
  const r = X.runHook(C4, dir, X.stopInput(dir, sid, X.NON_DIALOG()));
  assert.strictEqual(r.status, 2, `rc 2 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.ok(r.json && typeof r.json.reason === "string" && r.json.reason.includes(AUQ_GUIDANCE),
    `the reason carries the AskUserQuestion guidance (got ${r.stdout})`);
});
caseEnd();

caseBegin("c4-mechanism-lane-unchanged", "hooks/stop-premature-stop-guard.js");
test("a stalled step plus a dialog transcript still emits the mechanism-failure block", () => {
  const { dir, sid } = started("mech");
  X.markSteps(dir, sid, [["research", "in_progress"]]);
  X.backdateStep(dir, sid, "research", 30 * 60 * 60 * 1000);
  const r = X.runHook(C4, dir, X.stopInput(dir, sid, X.DIALOG()));
  assert.strictEqual(r.status, 2, `rc 2 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.ok(r.json && /\[C4 mechanism-failure\]/.test(r.json.reason), `mechanism block (got ${r.stdout})`);
});
caseEnd();

caseBegin("c2-alert-armed-dialog-turn", "hooks/supervisor-guard.js");
function armed(tag) {
  const s = started(tag);
  X.seedSup(s.dir, s.sid, { alert: { alert_armed_at: new Date().toISOString(), alert_phase: "pending" } });
  return s;
}
test("control: alert armed + non-dialog transcript -> C2 blocks", () => {
  const { dir, sid } = armed("c2ctl");
  const r = X.runHook(C2, dir, X.stopInput(dir, sid, X.NON_DIALOG()));
  assert.strictEqual(r.status, 2, `rc 2 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.ok(r.json && r.json.decision === "block");
});
test("alert armed + dialog transcript (text answer after Grep) -> C2 silent", () => {
  const { dir, sid } = armed("c2dlg");
  const r = X.runHook(C2, dir, X.stopInput(dir, sid, X.DIALOG()));
  assert.strictEqual(r.status, 0, `rc 0 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.ok(!r.json || r.json.decision !== "block", `no block (got ${r.stdout})`);
});
test("alert armed + a turn ending in AskUserQuestion -> C2 silent", () => {
  const { dir, sid } = armed("c2auq");
  const r = X.runHook(C2, dir, X.stopInput(dir, sid, AUQ_END()));
  assert.strictEqual(r.status, 0, `rc 0 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.ok(!r.json || r.json.decision !== "block", `no block (got ${r.stdout})`);
});
caseEnd();

// #2731 S3-10: the cumSev=error block shows the user only a fact line; the reason is unchanged.
caseBegin("c2-cumsev-error-fact-line", "hooks/supervisor-guard.js");
test("cumSev=error + non-dialog -> systemMessage is [EM Supervisor] block severity=error findings=<N>", () => {
  const C = require("../lib/system-message-contract");
  const s = started("c2err");
  const f = (d) => ({ categories: ["workflow"], severity: "error", detail: d, reporter: "test", timestamp: new Date().toISOString() });
  X.seedSup(s.dir, s.sid, { alert: { cumulative_severity: "error", findings: [f("e-one"), f("e-two")] } });
  const r = X.runHook(C2, s.dir, X.stopInput(s.dir, s.sid, X.NON_DIALOG()));
  assert.strictEqual(r.status, 2, `rc 2 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.ok(r.json && r.json.decision === "block" && typeof r.json.reason === "string", `a block with a reason (got ${r.stdout})`);
  assert.strictEqual(r.json.systemMessage, "[EM Supervisor] block severity=error findings=2");
  C.assertSystemMessageContract(r.json.systemMessage);
  assert.ok(r.json.reason.length > r.json.systemMessage.length, "the model-facing reason keeps its explanation");
});
caseEnd();

caseBegin("matrix-row-user-dialog-turn", "hooks/lib/stop-exemption-policy.js");
test("EXEMPTION_MATRIX row user-dialog-turn = {c4:true, c2:true, nextStep:false, promptNotify:false}", () => {
  const { EXEMPTION_MATRIX } = require(X.lib("hooks/lib/stop-exemption-policy.js"));
  assert.deepStrictEqual(EXEMPTION_MATRIX["user-dialog-turn"], { c4: true, c2: true, nextStep: false, promptNotify: false });
});
caseEnd();

// #2920 S5-1 / S5-4: an aborted session (workflow_aborted in its stream) quiets C4 on both lanes
// and C2 / C3 through supervisor-guard's early exit. The abort is pushed at the stream level so the
// hooks alone are under test, not the writer.
function pushAbort(dir, sid, origin) {
  const fs = require("node:fs");
  const p = require("node:path").join(dir, `${sid}.json`);
  const s = JSON.parse(fs.readFileSync(p, "utf8"));
  const ev = { kind: "workflow_aborted", reason: "test abort", origin, provenance: "declared", at: new Date().toISOString(), seq: s.events.length + 1 };
  if (origin !== "abort-sentinel") ev.downstream_session_id = "downstream-2920";
  s.events.push(ev);
  fs.writeFileSync(p, JSON.stringify(s));
}
function aborted(tag, origin) {
  const s = started(tag);
  pushAbort(s.dir, s.sid, origin);
  return s;
}
const assertQuiet = (dir, sid, r) => {
  assert.strictEqual(r.status, 0, `rc 0 (stdout: ${r.stdout} stderr: ${r.stderr})`);
  assert.ok(!r.json || r.json.decision !== "block", `no block (got ${r.stdout})`);
};

caseBegin("c4-workflow-aborted-is-silent", "hooks/stop-premature-stop-guard.js");
for (const origin of ["abort-sentinel", "adopt-auto"]) {
  test(`#2920: an aborted (${origin}) session with a non-dialog turn: exit 0, no output, no finding`, () => {
    const { dir, sid } = aborted(`ab${origin.length}`, origin);
    const r = X.runHook(C4, dir, X.stopInput(dir, sid, X.NON_DIALOG()));
    assertQuiet(dir, sid, r);
    assert.strictEqual(r.stdout.trim(), "", "no decision payload");
    assert.deepStrictEqual(findingsOf(dir, sid), [], "no premature-stop finding");
  });
}
test("#2920: an aborted session with a stalled step: the mechanism lane is quiet too", () => {
  const { dir, sid } = started("abmech");
  X.markSteps(dir, sid, [["research", "in_progress"]]);
  X.backdateStep(dir, sid, "research", 30 * 60 * 60 * 1000);
  pushAbort(dir, sid, "abort-sentinel");
  const r = X.runHook(C4, dir, X.stopInput(dir, sid, X.NON_DIALOG()));
  assertQuiet(dir, sid, r);
  assert.ok(!/\[C4 (mechanism-failure|premature-stop)\]/.test(r.stdout), `no C4 block (got ${r.stdout})`);
});
caseEnd();

caseBegin("c4-workflow-aborted-rows", "hooks/stop-premature-stop-guard.js");
const stubDeps = (over) => Object.assign({
  isWorkflowOff: () => false, isNextStepPaused: () => false, isWorkflowStarted: () => true,
  anyStepInFlight: () => false, isLookaheadOnlyInFlight: () => false, isUserDialogTurn: () => false,
  isWorkflowAborted: () => false,
}, over || {});
test("#2920: buildExemptionDeps carries isWorkflowAborted", () => {
  const g = require(X.lib(C4));
  assert.strictEqual(typeof g.buildExemptionDeps().isWorkflowAborted, "function");
});
test("#2920: session row workflow-aborted holds exactly when isWorkflowAborted(sid) does", () => {
  const g = require(X.lib(C4));
  const seen = [];
  const deps = stubDeps({ isWorkflowAborted: (sid) => { seen.push(sid); return true; } });
  assert.strictEqual(g.firstExemption("session", { sid: "s-ab" }, deps, []), "workflow-aborted");
  assert.deepStrictEqual(seen, ["s-ab"], "predicate called with the sid");
  assert.strictEqual(g.firstExemption("session", { sid: "s-ab" }, stubDeps(), []), null, "control: not aborted");
});
test("#2920: next-step-output row workflow-aborted-reason holds for REASON workflow-aborted*", () => {
  const g = require(X.lib(C4));
  for (const reason of ["workflow-aborted", "workflow-aborted-cleanup"]) {
    assert.strictEqual(g.firstExemption("next-step-output", { sid: "s", reason }, stubDeps(), []), "workflow-aborted-reason", reason);
  }
  for (const reason of ["cleanup", "no-state", "aborted"]) {
    assert.strictEqual(g.firstExemption("next-step-output", { sid: "s", reason }, stubDeps(), []), null, `control ${reason}`);
  }
});
test("#2920 M1-f: EXEMPTION_MATRIX rows workflow-aborted / workflow-aborted-reason = {c4:true, c2:false, nextStep:false, promptNotify:false}", () => {
  const { EXEMPTION_MATRIX } = require(X.lib("hooks/lib/stop-exemption-policy.js"));
  for (const id of ["workflow-aborted", "workflow-aborted-reason"]) {
    assert.deepStrictEqual(EXEMPTION_MATRIX[id], { c4: true, c2: false, nextStep: false, promptNotify: false }, id);
  }
});
caseEnd();

caseBegin("c2-workflow-aborted-early-exit", "hooks/supervisor-guard.js");
test("#2920: control — alert armed + non-dialog on a live session still blocks", () => {
  const { dir, sid } = armed("c2abctl");
  const r = X.runHook(C2, dir, X.stopInput(dir, sid, X.NON_DIALOG()));
  assert.strictEqual(r.status, 2, `rc 2 (stdout: ${r.stdout} stderr: ${r.stderr})`);
});
for (const origin of ["abort-sentinel", "abort-cli"]) {
  test(`#2920: alert armed + non-dialog on an aborted (${origin}) session -> C2 silent, alert untouched`, () => {
    const { dir, sid } = armed(`c2ab${origin.length}`);
    pushAbort(dir, sid, origin);
    const before = X.readSup(dir, sid);
    const r = X.runHook(C2, dir, X.stopInput(dir, sid, X.NON_DIALOG()));
    assertQuiet(dir, sid, r);
    assert.strictEqual(r.stdout.trim(), "", `no output (got ${r.stdout})`);
    assert.deepStrictEqual(X.readSup(dir, sid).alert, before.alert, "the alert was consumed");
  });
}
caseEnd();
