#!/usr/bin/env node
// tests/hooks/feature-2936-turn-tail-callers.js
// Tests: hooks/stop-final-report-guard.js, hooks/lib/user-dialog-turn.js, hooks/lib/jev/conversation-point.js, hooks/stop-sentinel-unapplied-notice.js, hooks/supervisor-guard/detect.js, hooks/stop-confirm-plan-guard.js
// Tags: TL2, hooks, transcript-reader, stop-guard, final-report, user-dialog-turn, jev, conversation-point, sentinel, supervisor-guard, regression, mock-server, scope:issue-specific
// TL3 gap: a real multi-MB session transcript written by the host while the hooks read it.
// #2936 S10: readTurnTail now reads a bounded tail. Each of its six callers, given a transcript whose
// history is past the first window (256 KiB), still gets what a whole-file read gave it: the boundary
// each one needs (a turn, the final-report heading, the opening prompt, an iso point) is still read.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after: afterAll, test } = require("node:test");
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2936tc-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.PLAN_SYNC_REMOTE_URL = "";
delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.PLAN_LANG;
process.chdir(SCRATCH);

const H = require("./feature-2936-turn-tail-read/fixture");
const R = require("./feature-2729-presentation-receipt/fixture");
const G = require("../lib/final-report-guard-fixture");
const J = require("./feature-2461-jev/fixture");
const mock = J.startMock(path.join(SCRATCH, "mock"));
afterAll(() => {
  mock.stop();
  process.chdir(os.tmpdir());
  restore();
  try { fs.rmSync(SCRATCH, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const { U, A, T, TU, TRS } = H;
const OLD = 400 * 1024;
const BIG = "b".repeat(300 * 1024);
const READ = (id) => ({ type: "tool_use", id, name: "Read", input: { file_path: "C:/example/a.txt" } });
const SENTINEL = 'echo "<<WORKFLOW_MARK_STEP_research_complete>>"';
const BASHU = (id, command) => ({ type: "tool_use", id, name: "Bash", input: { command } });
const lib = (rel) => require(path.join(H.ROOT, rel));
// deep(file) -> the file is past the first window, so a bounded reader must grow to answer.
// Every fixture below puts its boundary entry at least OLD (> W0) bytes before the end.
const deep = (file) => assert.ok(OLD > H.W0 && fs.statSync(file).size > OLD, `fixture: ${file} is past the first window`);
// The guard's reply-language check is config-dependent: pin it to the closings' language.
const STOP_ENV = { CONV_LANG: "english" };

caseBegin("final-report-heading-in-an-old-turn-is-still-found", "hooks/stop-final-report-guard.js");
test("a Final Report heading in a turn before the first window passes the guard", () => {
  const sid = "f2936-fr-old";
  G.writeEnv(sid);
  const file = H.write(SCRATCH, [
    ...H.history(64 * 1024), U("close the session", "u-close"), A("a-report", T(G.reportText(sid))),
    ...H.history(OLD), U("anything else?", "u-last"), A("a-last", T("Nothing else.")),
  ]);
  deep(file);
  const r = G.runGuard(sid, file, SCRATCH);
  assert.equal(r.rc, 0, `the heading is found, no block: ${r.out.slice(0, 300)} ${r.err.slice(0, 300)}`);
});
test("no Final Report heading anywhere still blocks", () => {
  const sid = "f2936-fr-none";
  G.writeEnv(sid);
  const file = H.write(SCRATCH, [...H.history(OLD), U("close the session", "u-close"), A("a-last", T("Session closed."))]);
  deep(file);
  const r = G.runGuard(sid, file, SCRATCH);
  assert.equal(r.rc, 2, `stdout: ${r.out.slice(0, 300)}`);
  assert.equal(r.decision, "block");
});
caseEnd();

caseBegin("user-dialog-turn-reads-the-whole-current-turn", "hooks/lib/user-dialog-turn.js");
test("isUserDialogTurn: a read-only turn with a 300 KB tool_result is dialog; a deep Bash call is not", () => {
  const UD = lib("hooks/lib/user-dialog-turn");
  const ro = H.write(SCRATCH, [...H.history(OLD), U("what does a.txt say?", "u-q"), A("a-r", READ("t-r")), TRS("t-r", "u-tr", BIG), A("a-ans", T("It says hello."))]);
  deep(ro);
  assert.equal(UD.isUserDialogTurn({ transcript_path: ro }), true, "read-only answer to a human prompt");
  const bash = H.write(SCRATCH, [...H.history(OLD), U("what does a.txt say?", "u-q"), A("a-b", TU("t-b")), TRS("t-b", "u-tb", BIG), A("a-ans", T("It says hello."))]);
  assert.equal(UD.isUserDialogTurn({ transcript_path: bash }), false, "the Bash call before the big result is still seen");
});

// stamped(gaps) -> prompts P0..P3 stamped a minute apart, ~300 KB of prompt-less filler between them.
const MIN = 60 * 1000;
const T0 = Date.parse("2026-03-01T00:00:00.000Z");
const iso = (k) => new Date(T0 + k * MIN).toISOString();
function stamped(unstamped) {
  const out = [];
  for (let k = 0; k < 4; k++) {
    const extra = unstamped === k ? {} : { timestamp: iso(k) };
    out.push(U(`prompt ${k}`, `u-p${k}`, extra), ...H.history(300 * 1024, { prompts: false }));
  }
  out.push(A("a-end", T("done")));
  return out;
}
test("countHumanPromptsSince: an iso deep in the history counts the prompts after it", () => {
  const UD = lib("hooks/lib/user-dialog-turn");
  const file = H.write(SCRATCH, stamped(-1));
  deep(file);
  const at = (isoStr) => UD.countHumanPromptsSince({ transcript_path: file }, isoStr);
  assert.equal(at(new Date(T0 + MIN / 2).toISOString()), 3, "after P0: P1, P2, P3");
  assert.equal(at(new Date(T0 - MIN).toISOString()), 4, "before every prompt: read to the start");
  assert.equal(at(new Date(T0 + 2.5 * MIN).toISOString()), 1, "after P2: P3 only");
  assert.equal(at(new Date(T0 + 9 * MIN).toISOString()), 0, "after the last prompt");
});
test("countHumanPromptsSince: an unstamped prompt after the iso point gives null", () => {
  const UD = lib("hooks/lib/user-dialog-turn");
  const file = H.write(SCRATCH, stamped(2));
  assert.equal(UD.countHumanPromptsSince({ transcript_path: file }, new Date(T0 + MIN / 2).toISOString()), null);
  assert.equal(UD.countHumanPromptsSince({ transcript_path: file }, new Date(T0 + 3.5 * MIN).toISOString()), 0, "the unstamped prompt is before P3");
});
caseEnd();

caseBegin("conversation-point-sends-the-opening-prompt-past-the-window", "hooks/lib/jev/conversation-point.js");
test("judgeConversation: the non-sidechain opening prompt and the current turn are in the state", () => {
  mock.conv(0.02);
  const sc = J.scene(SCRATCH, "cp-deep");
  const sid = J.newSid();
  const tp = J.writeTranscript(sc, "t", [
    ...H.history(OLD), U("use Markdown for every report PROMPT-9292", "u-open"), A("a-long", T(BIG)),
    U("subagent task SIDE-1111", "u-side", { isSidechain: true }), A("a-turn", T("Next I will edit report.js. TURN-4242")),
  ]);
  deep(tp);
  const CONV = J.lib("hooks/lib/jev/conversation-point.js");
  const OVR = J.lib("hooks/lib/jev/test-overrides.js");
  const out = J.nodeEval(sc, mock, `(async () => {
const r = await require(${JSON.stringify(CONV)}).judgeConversation({ point: "continuation", direction: "continue-on-stop",
  sessionId: process.argv[2], transcriptPath: process.argv[3], judgedIn: { kind: "cli", name: "test" }, extra: {},
  overrides: require(${JSON.stringify(OVR)}).captureTestOverrides(process.env) });
console.log(JSON.stringify({ r: r === undefined ? null : r }));
})();`, [sid, tp]);
  assert.equal(out.status, 0, out.stderr.slice(0, 600));
  const reqs = mock.requests();
  assert.equal(reqs.length, 1, "exactly one query");
  const st = JSON.parse(reqs[0].body_text).state;
  assert.ok(st.includes("[user prompt that opened this turn]\nUser: use Markdown for every report PROMPT-9292"), "the opening prompt block is sent");
  assert.ok(st.includes("TURN-4242"), "the current turn is sent");
  assert.ok(!st.includes("old prompt"), "no older turn's prompt is sent");
});
caseEnd();

caseBegin("sentinel-notice-sees-a-sentinel-deep-in-the-turn", "hooks/stop-sentinel-unapplied-notice.js");
function runNotice(sid, file) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  const r = childProcess.spawnSync(process.execPath, [path.join(H.ROOT, "hooks/stop-sentinel-unapplied-notice.js")], {
    input: JSON.stringify({ session_id: sid, transcript_path: file, hook_event_name: "Stop", stop_hook_active: false, cwd: SCRATCH }),
    env, cwd: SCRATCH, encoding: "utf8", timeout: 60000,
  });
  assert.equal(r.status, 0, r.stderr);
  const text = String(r.stdout || "").trim();
  return text ? JSON.parse(text) : {};
}
test("an unreached sentinel before a 300 KB result of the same turn is told; an old turn's is not", () => {
  const sid = "f2936-sn-deep";
  lib("hooks/workflow-state/state-io").markStep(sid, "workflow_init", "complete");
  const file = H.write(SCRATCH, [
    U("first", "u-1"), A("a-old", BASHU("toolu_f2936_old", SENTINEL)), TRS("toolu_f2936_old", "u-old", "ok"), A("a-1", T("one")),
    ...H.history(OLD), U("go", "u-go"), A("a-s", BASHU("toolu_f2936_new", SENTINEL)), TRS("toolu_f2936_new", "u-sr", "ok"),
    A("a-r", READ("t-r")), TRS("t-r", "u-tr", BIG), A("a-done", T("done")),
  ]);
  deep(file);
  const out = runNotice(sid, file);
  assert.equal(typeof out.systemMessage, "string", `a notice: ${JSON.stringify(out).slice(0, 300)}`);
  assert.match(out.systemMessage, /research/);
  assert.equal(out.systemMessage.split("\n").length, 2, `a header and one line: the old turn's sentinel is not told: ${out.systemMessage}`);
  assert.equal(out.decision, undefined, "notice only");
});
caseEnd();

caseBegin("detect-sentinel-hang-after-a-large-history", "hooks/supervisor-guard/detect.js");
test("detectSentinelHang sees the last assistant entry's sentinel after a large history and turn", () => {
  const D = lib("hooks/supervisor-guard/detect");
  const hang = H.write(SCRATCH, [...H.history(OLD), U("go", "u-go"), A("a-r", READ("t-r")), TRS("t-r", "u-tr", BIG), A("a-s", T("Marking."), BASHU("t-s", SENTINEL))]);
  deep(hang);
  assert.equal(D.detectSentinelHang(hang), true);
  const moved = H.write(SCRATCH, [...H.history(OLD), U("go", "u-go"), A("a-r", READ("t-r")), TRS("t-r", "u-tr", BIG), A("a-s", BASHU("t-s", SENTINEL), READ("t-n"))]);
  assert.equal(D.detectSentinelHang(moved), false, "a tool_use after the sentinel is not a hang");
});
caseEnd();

caseBegin("confirm-plan-guard-reads-the-presentation-turn-past-the-window", "hooks/stop-confirm-plan-guard.js");
// presented(s, closing, o) -> a transcript: a large history, then one turn that rewrote the plan,
// read a 300 KB file, and ended with `closing`; o.marker false writes no turn marker.
function presented(s, closing, o) {
  const opt = o || {};
  if (opt.marker !== false) R.turnMarker(s.sid, s.stage, s.plan);
  const before = opt.before || H.history(OLD);
  return R.writeTranscript(s.sid, [
    ...before, R.U("write the plan", "u-prompt"), R.A("a-w1", R.W(s.plan, "w1")), R.TR("w1", "u-tr1"),
    A("a-r", READ("t-r")), TRS("t-r", "u-tr2", BIG), R.A("a-anchor", R.T(closing)),
  ]);
}
test("a presentation turn whose prompt is past the first window continues and writes the receipt", () => {
  const s = R.sessionAt("outline", { tag: 9361 });
  const closing = "Here is the plan.\n\n" + s.urlLine;
  const tp = presented(s, closing);
  deep(tp);
  const st = R.stop(s.sid, tp, { cfg: R.cfg(), env: STOP_ENV, input: { last_assistant_message: closing } });
  assert.ok(st.continued, `continue: rc=${st.rc} ${st.out.slice(0, 300)} ${st.err.slice(0, 300)}`);
  const rec = R.readReceiptRaw(s.sid, "outline");
  assert.ok(rec, "the receipt is written");
  assert.equal(rec.anchorUuid, "a-anchor");
});
test("an old turn's presentation does not make a later plain turn continue", () => {
  const s = R.sessionAt("outline", { tag: 9362 });
  const old = [R.U("write it", "u-old"), R.A("a-old", R.T("Here is the plan.\n\n" + s.urlLine)), ...H.history(OLD)];
  const tp = presented(s, "All done for now.", { marker: false, before: old });
  deep(tp);
  const st = R.stop(s.sid, tp, { cfg: R.cfg(), env: STOP_ENV, input: { last_assistant_message: "All done for now." } });
  assert.ok(!st.continued, `no continue: ${st.out.slice(0, 300)}`);
  assert.ok(!R.receiptExists(s.sid, "outline"), "no receipt");
});
caseEnd();
