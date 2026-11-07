#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/mechanism-failure.js, hooks/lib/sentinel-patterns.js, hooks/workflow-mark/workflow-abort-handler.js, hooks/workflow-mark.js, hooks/user-prompt-submit-mechanism-check.js
// Tags: TL2, workflow-abort, workflow-mark, sentinel, mechanism-failure, regression-2920, scope:issue-specific, pwsh-not-required
// lang-check: ignore — the Japanese abort reason below is test INPUT (a non-ASCII sentinel reason must round-trip).
// #2920 S5-2 and S6: an aborted session reports no stalled step, and the
// <<WORKFLOW_ABORT_ACCEPTED: {reason}>> sentinel records the abort through the real
// PostToolUse hook (or refuses aloud, recording nothing).
// TL3 gap (what this test does NOT catch):
// - the ask permission prompt the user answers before the sentinel runs (settings.json is
//   checked by tests/install/feature-supervisor-settings-registration.sh).

const { test, after } = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const NEUTRAL = fs.mkdtempSync(path.join(os.tmpdir(), "f2920h-"));
fs.mkdirSync(path.join(NEUTRAL, "transcripts-empty"));
after(() => {
  restore();
  fs.rmSync(NEUTRAL, { recursive: true, force: true });
});

const X = require("./feature-2920-workflow-abort/fixture");
const M = require("../lib/workflow-mark-output");
const mech = () => X.mod("hooks/lib/mechanism-failure");
const SP = () => X.mod("hooks/lib/sentinel-patterns");

const sentinel = (reason) => `echo "<<WORKFLOW_ABORT_ACCEPTED: ${reason}>>"`;
const mark = (sid, command, extra) => M.runMark(M.bashPayload(command, Object.assign({ sid }, extra || {})), {
  cwd: NEUTRAL, env: { CLAUDE_TRANSCRIPT_BASE_DIR: path.join(NEUTRAL, "transcripts-empty") },
});
const failIf = (why) => { if (why) assert.fail(why); };
const OLD = "2020-01-01T00:00:00.000Z";

caseBegin("aborted-session-reports-no-stall", "hooks/lib/mechanism-failure.js");
test("S5-2: control — a stale in_progress write_code is in-flight-expired", () => {
  X.seedPlain("mf-control");
  X.pushStep("mf-control", "write_code", "in_progress", OLD);
  assert.deepStrictEqual(mech().detectStalledSteps("mf-control"), [{ step: "write_code", kind: "in-flight-expired" }]);
});
test("S5-2: the same stall in an aborted session reports nothing", () => {
  X.seedPlain("mf-aborted");
  X.pushStep("mf-aborted", "write_code", "in_progress", OLD);
  X.rawAbort("mf-aborted", "abort-sentinel");
  // The state stays readable, so an empty answer is the abort, not the total catch.
  assert.strictEqual(X.io().readState("mf-aborted").steps.write_code.status, "in_progress", "fixture readable");
  assert.deepStrictEqual(mech().detectStalledSteps("mf-aborted"), []);
});
test("S5-2: an adopt-auto abort silences the stall too", () => {
  X.seedPlain("mf-adopted");
  X.pushStep("mf-adopted", "write_code", "in_progress", OLD);
  X.rawAbort("mf-adopted", "adopt-auto");
  assert.strictEqual(X.io().readState("mf-adopted").steps.write_code.status, "in_progress", "fixture readable");
  assert.deepStrictEqual(mech().detectStalledSteps("mf-adopted"), []);
});
caseEnd();

caseBegin("sentinel-patterns", "hooks/lib/sentinel-patterns.js");
test("S6: the abort sentinel is a sentinel and a strict sentinel; a chained form is not strict", () => {
  const sp = SP();
  assert.ok(sp.RE_WORKFLOW_ABORT_ACCEPTED_DQ instanceof RegExp, "RE_WORKFLOW_ABORT_ACCEPTED_DQ");
  assert.ok(sp.LOOKSLIKE_WORKFLOW_ABORT_ACCEPTED instanceof RegExp, "LOOKSLIKE_WORKFLOW_ABORT_ACCEPTED");
  const ok = sentinel("user stopped the work");
  assert.strictEqual(sp.isSentinel(ok), true, "isSentinel");
  assert.strictEqual(sp.isStrictSentinel(ok), true, "isStrictSentinel");
  assert.deepStrictEqual((ok.match(sp.RE_WORKFLOW_ABORT_ACCEPTED_DQ) || [])[1], "user stopped the work", "reason group");
  assert.strictEqual(sp.isStrictSentinel(`${ok} && rm -rf x`), false, "chained");
  assert.strictEqual(sp.isSentinel('echo "<<WORKFLOW_ABORT_ACCEPTED>>"'), true, "looks-like form is caught");
});
// dq = the reason group RE_WORKFLOW_ABORT_ACCEPTED_DQ captures (null: no match); look / sentinel /
// strict = LOOKSLIKE, isSentinel, isStrictSentinel. undefined = no claim for that column.
const LONG = "stopped " + "y".repeat(2000);
const SENTINEL_TABLE = [
  { name: "canonical", input: sentinel("user stopped the work"), dq: "user stopped the work", look: true, sentinel: true, strict: true },
  { name: "reason-one-char", input: sentinel("x"), dq: "x", look: true, sentinel: true, strict: true },
  { name: "reason-long", input: sentinel(LONG), dq: LONG, look: true, sentinel: true, strict: true },
  { name: "reason-japanese", input: sentinel("方針変更のため中止"), dq: "方針変更のため中止", look: true, sentinel: true, strict: true },
  { name: "reason-empty", input: 'echo "<<WORKFLOW_ABORT_ACCEPTED: >>"', dq: null, look: true, sentinel: true },
  { name: "reason-with-gt", input: sentinel("a>b"), dq: null, look: true, sentinel: true },
  { name: "lookslike-no-reason", input: 'echo "<<WORKFLOW_ABORT_ACCEPTED>>"', dq: null, look: true, sentinel: true, strict: false },
  { name: "lookslike-no-space", input: 'echo "<<WORKFLOW_ABORT_ACCEPTED:stop now>>"', dq: null, look: true, sentinel: true, strict: false },
  { name: "chained-and", input: `${sentinel("user stopped")} && rm -rf x`, dq: null, look: false, strict: false },
  { name: "chained-semicolon", input: `${sentinel("user stopped")}; true`, dq: null, look: false, strict: false },
  { name: "leading-text", input: `x ${sentinel("user stopped")}`, dq: null, look: false, strict: false },
  { name: "single-quoted", input: "echo '<<WORKFLOW_ABORT_ACCEPTED: user stopped>>'", dq: null, look: false, strict: false },
  { name: "lowercase", input: 'echo "<<workflow_abort_accepted: user stopped>>"', dq: null, look: false, sentinel: false, strict: false },
  { name: "prefix-collision", input: 'echo "<<WORKFLOW_ABORT_ACCEPTED_EXTRA: user stopped>>"', dq: null, look: false, strict: false },
  { name: "other-family", input: 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: user stopped>>"', dq: null, look: false, sentinel: true },
];
test("S6 table: RE_WORKFLOW_ABORT_ACCEPTED_DQ / LOOKSLIKE / isSentinel / isStrictSentinel per row", () => {
  const sp = SP();
  assert.ok(sp.RE_WORKFLOW_ABORT_ACCEPTED_DQ instanceof RegExp && sp.LOOKSLIKE_WORKFLOW_ABORT_ACCEPTED instanceof RegExp, "the two regex constants are exported");
  for (const { name, input, dq, look, sentinel: isS, strict } of SENTINEL_TABLE) {
    const m = input.match(sp.RE_WORKFLOW_ABORT_ACCEPTED_DQ);
    assert.strictEqual(m ? m[1] : null, dq, `${name}: DQ reason group`);
    assert.strictEqual(sp.LOOKSLIKE_WORKFLOW_ABORT_ACCEPTED.test(input), look, `${name}: LOOKSLIKE`);
    if (isS !== undefined) assert.strictEqual(sp.isSentinel(input), isS, `${name}: isSentinel`);
    if (strict !== undefined) assert.strictEqual(sp.isStrictSentinel(input), strict, `${name}: isStrictSentinel`);
  }
});
caseEnd();

caseBegin("handler-module", "hooks/workflow-mark/workflow-abort-handler.js");
test("S6: handle() declines other sentinels and owns the abort sentinel", () => {
  const h = X.mod("hooks/workflow-mark/workflow-abort-handler");
  const sink = { info: [], unapplied: [] };
  const ctx = (cmd, sid) => ({ cmd, sessionId: sid, pushMessage: (m) => sink.info.push(m), pushUnapplied: (m) => sink.unapplied.push(m) });
  assert.strictEqual(h.handle(ctx('echo "<<WORKFLOW_MARK_STEP_research_complete>>"', "hm-x")), false, "foreign sentinel");
  X.seedPlain("hm-ok");
  assert.strictEqual(h.handle(ctx(sentinel("user stopped the work"), "hm-ok")), true, "own sentinel");
  assert.deepStrictEqual(sink.unapplied, [], "refusals");
  assert.strictEqual(X.mod(X.ABORT_MODULE).isWorkflowAborted("hm-ok"), true, "recorded");
});
caseEnd();

caseBegin("handlers-registration", "hooks/workflow-mark.js");
test("S6: HANDLERS lists the abort handler after glossaryAcceptHandler and before markStepHandler", () => {
  const src = fs.readFileSync(path.join(X.ROOT, "hooks", "workflow-mark.js"), "utf8");
  const req = src.match(/const (\w+) = require\("\.\/workflow-mark\/workflow-abort-handler"\)/);
  assert.ok(req, "workflow-abort-handler is not required");
  const list = (src.match(/const HANDLERS = \[([\s\S]*?)\];/) || [])[1] || "";
  const pos = (n) => list.search(new RegExp(`\\b${n}\\b`));
  const [g, w, m] = [pos("glossaryAcceptHandler"), pos(req[1]), pos("markStepHandler")];
  assert.ok(g >= 0 && w > g && m > w, `order glossary=${g} abort=${w} markStep=${m}`);
});
caseEnd();

caseBegin("sentinel-records-abort", "hooks/workflow-mark.js");
test("S6: the sentinel on a started session records an abort-sentinel abort and points at /worktree-end", () => {
  X.seedPlain("wm-ok");
  const r = mark("wm-ok", sentinel("user stopped the work"));
  failIf(M.infoFailure(r, /worktree-end/));
  assert.deepStrictEqual(X.abortEventsOf("wm-ok").map((e) => [e.origin, e.reason, e.provenance]), [["abort-sentinel", "user stopped the work", "declared"]]);
});
caseEnd();

caseBegin("sentinel-refusals", "hooks/workflow-mark.js");
function refused(sid, command, pattern, extra) {
  const r = mark(sid, command, extra);
  failIf(M.unappliedFailure(r, pattern));
  assert.strictEqual(X.abortEventsOf(sid).length, 0, "abort recorded");
}
test("S6: a session that has not started is refused", () => {
  X.io().writeState("wm-unstarted", X.io().createInitialState("wm-unstarted", X.CTX));
  refused("wm-unstarted", sentinel("user stopped the work"), /start|init/i);
});
test("S6: a delivered session is refused", () => {
  X.seedPlain("wm-delivered");
  X.pushStep("wm-delivered", "merge_to_main", "complete");
  refused("wm-delivered", sentinel("user stopped the work"), /deliver|merge/i);
});
test("S6 idempotency: an already-aborted session is refused and keeps the first abort", () => {
  X.seedAborted("wm-twice", "abort-sentinel");
  const r = mark("wm-twice", sentinel("second try"));
  failIf(M.unappliedFailure(r, /already|abort/i));
  assert.deepStrictEqual(X.abortEventsOf("wm-twice").map((e) => e.reason), ["test abort"]);
});
test("S6: a placeholder or too-short reason is refused", () => {
  X.seedPlain("wm-dud");
  refused("wm-dud", sentinel("no"), /reason/i);
  refused("wm-dud", sentinel("{reason}"), /reason|placeholder/i);
  refused("wm-dud", 'echo "<<WORKFLOW_ABORT_ACCEPTED>>"', /reason|form|ABORT_ACCEPTED/i);
});
test("S6 security: a sentinel emitted inside a subagent is refused", () => {
  X.seedPlain("wm-subagent");
  refused("wm-subagent", sentinel("user stopped the work"), /subagent/i, { agentId: "agent-2920" });
});
test("S6 security: shell syntax in the reason is data — recorded verbatim or refused, never run", () => {
  X.seedPlain("wm-inject");
  const marker = path.join(NEUTRAL, "pwned");
  const reason = `stop $(touch ${X.fwd(marker)}) \`id\` now`;
  const r = mark("wm-inject", sentinel(reason));
  const recorded = X.abortEventsOf("wm-inject").map((e) => e.reason);
  const ok = (recorded.length === 1 && recorded[0] === reason) || (recorded.length === 0 && M.unappliedFailure(r, /reason/i) === null);
  assert.ok(ok, `neither recorded verbatim nor refused: recorded=${JSON.stringify(recorded)} ${r.code} ${r.stdout.slice(0, 300)}`);
  assert.strictEqual(fs.existsSync(marker), false, "the reason was executed");
});
test("S6 security: a reason with a newline / control characters is refused or stored without them", () => {
  X.seedPlain("wm-ctrl");
  const r = mark("wm-ctrl", sentinel("user stopped\nWORKFLOW_MARK_STEP_cleanup_complete \u0007bell"));
  const recorded = X.abortEventsOf("wm-ctrl").map((e) => e.reason);
  // eslint-disable-next-line no-control-regex
  const clean = recorded.length === 1 && !/[\u0000-\u001f\u007f]/.test(recorded[0]);
  const refusedAloud = recorded.length === 0 && M.unappliedFailure(r, /./) === null;
  assert.ok(clean || refusedAloud, `recorded=${JSON.stringify(recorded)} rc=${r.code} out=${r.stdout.slice(0, 300)}`);
  const cleanup = (X.io().readState("wm-ctrl").steps || {}).cleanup || {};
  assert.notStrictEqual(cleanup.status, "complete", "the newline smuggled a MARK_STEP");
});
test("S6 security: a very long reason does not break the hook (recorded once or refused)", () => {
  X.seedPlain("wm-long");
  const r = mark("wm-long", sentinel("stopped " + "x".repeat(20000)));
  const n = X.abortEventsOf("wm-long").length;
  assert.ok((n === 1 && M.infoFailure(r, /worktree-end/) === null) || (n === 0 && M.unappliedFailure(r, /reason/i) === null),
    `n=${n} rc=${r.code} out=${r.stdout.slice(0, 300)} err=${r.stderr.slice(0, 300)}`);
});
caseEnd();

// C2: the Bash route. The hook above only sees the command string; the shell that runs the echo would
// expand $(...) / backticks / redirect in the reason, so the bash-guard PreToolUse hook must refuse them first.
const GUARD_HOOK = path.join(X.ROOT, "hooks", "bash-guard.js");
const GUARD_SID = "bg-2920";
const GUARD_HOME = path.join(NEUTRAL, "guard-home");
fs.mkdirSync(path.join(GUARD_HOME, ".claude"), { recursive: true });
fs.writeFileSync(path.join(GUARD_HOME, ".claude", "settings.json"), '{"permissions":{"allow":[],"deny":[]}}\n');
function guard(command) {
  const input = { session_id: GUARD_SID, hook_event_name: "PreToolUse", cwd: NEUTRAL, tool_name: "Bash", tool_input: { command } };
  const env = Object.assign({}, process.env, { CONV_LANG: "english", HOME: GUARD_HOME, USERPROFILE: GUARD_HOME,
    CLAUDE_TRANSCRIPT_BASE_DIR: path.join(NEUTRAL, "transcripts-empty") });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [GUARD_HOOK], { input: JSON.stringify(input), cwd: NEUTRAL, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `bash-guard exit ${r.status}: ${r.stderr}`);
  return JSON.parse(String(r.stdout).trim() || "{}");
}

caseBegin("sentinel-shell-syntax-bash-route", "hooks/workflow-mark/workflow-abort-handler.js");
test("S6 security (bash route): a reason carrying $(...) or a backtick is explicitly blocked, and nothing runs or is recorded", () => {
  for (const [name, tag] of [["command-substitution", "cs"], ["backtick", "bt"]]) {
    const sid = `wm-bash-${tag}`;
    X.seedPlain(sid);
    const marker = path.join(NEUTRAL, `bash-route-${tag}`);
    const inner = `touch ${X.fwd(marker)}`;
    const reason = name === "backtick" ? `stop \`${inner}\` now` : `stop $(${inner}) now`;
    const command = sentinel(reason);
    const j = guard(command);
    // An unset decision must fail: only an explicit block/deny counts as refused.
    const denied = j.decision === "block" || j.decision === "deny" || (j.hookSpecificOutput || {}).permissionDecision === "deny";
    assert.ok(denied, `${name}: bash-guard did not explicitly block: ${JSON.stringify(j).slice(0, 300)}`);
    // The harness runs the command only when the guard lets it through; mirror that on the same input.
    if (!denied) {
      spawnSync("bash", ["-c", command], { cwd: NEUTRAL, encoding: "utf8", timeout: 60000 });
      mark(sid, command);
    }
    assert.strictEqual(fs.existsSync(marker), false, `${name}: the reason was executed`);
    assert.strictEqual(X.abortEventsOf(sid).length, 0, `${name}: an abort event was recorded`);
  }
});
test("S6 security (bash route): a > inside the quoted reason is inert — a real bash run creates no file", () => {
  const marker = path.join(NEUTRAL, "bash-gt-out");
  const r = spawnSync("bash", ["-c", sentinel(`stop > ${X.fwd(marker)} now`)], { cwd: NEUTRAL, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `bash exit ${r.status}: ${r.stderr}`);
  assert.strictEqual(fs.existsSync(marker), false, "the quoted > was executed as a redirect");
});
test("S6 security (bash route): the plain-reason sentinel is not blocked as shell syntax (symmetric control)", () => {
  const j = guard(sentinel("user stopped the work"));
  assert.notStrictEqual(j.decision, "block", `a plain reason was blocked: ${JSON.stringify(j).slice(0, 300)}`);
});
test("S6 security (hook route): a > in the reason is data — recorded verbatim or refused, never redirected", () => {
  X.seedPlain("wm-gt");
  const marker = path.join(NEUTRAL, "gt-out");
  const reason = `stop > ${X.fwd(marker)} now`;
  const r = mark("wm-gt", sentinel(reason));
  const recorded = X.abortEventsOf("wm-gt").map((e) => e.reason);
  const ok = (recorded.length === 1 && recorded[0] === reason) || (recorded.length === 0 && M.unappliedFailure(r, /reason/i) === null);
  assert.ok(ok, `neither recorded verbatim nor refused: recorded=${JSON.stringify(recorded)} ${r.code} ${r.stdout.slice(0, 300)}`);
  assert.strictEqual(fs.existsSync(marker), false, "the redirect was executed");
});
caseEnd();

// promptHook(sid) — the real UserPromptSubmit hook as a subprocess; returns its parsed stdout.
const PROMPT_HOOK = path.join(X.ROOT, "hooks", "user-prompt-submit-mechanism-check.js");
const CFG = path.join(NEUTRAL, "cfg");
fs.mkdirSync(CFG);
function promptHook(sid) {
  const env = Object.assign({}, process.env, { AGENTS_MAIN_ROOT: CFG, CLAUDE_TRANSCRIPT_BASE_DIR: path.join(NEUTRAL, "transcripts-empty") });
  delete env.CLAUDE_CODE_SESSION_ID;
  const input = { session_id: sid, transcript_path: "", prompt: "where are we?", hook_event_name: "UserPromptSubmit" };
  const r = spawnSync(process.execPath, [PROMPT_HOOK], { input: JSON.stringify(input), cwd: NEUTRAL, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `hook exit ${r.status}: ${r.stderr}`);
  return { json: JSON.parse(r.stdout || "{}"), show: `stdout=${String(r.stdout).slice(0, 400)}` };
}
const stalled = (sid) => { X.seedPlain(sid); X.pushStep(sid, "write_code", "in_progress", OLD); };

caseBegin("prompt-hook-quiet-after-abort", "hooks/user-prompt-submit-mechanism-check.js");
test("S5-2: control — the real UserPromptSubmit hook surfaces a stale write_code on a live session", () => {
  stalled("ups-live");
  const r = promptHook("ups-live");
  assert.strictEqual(r.json.blocks, true, r.show);
  assert.ok(/^\[mechanism-failure\] .*write_code/.test(r.json.systemMessage || ""), r.show);
});
for (const origin of ["abort-sentinel", "adopt-auto", "abort-cli"]) {
  test(`S5-2: the same stall after a ${origin} abort: the hook prints no notice and blocks nothing`, () => {
    const sid = `ups-${origin}`;
    stalled(sid);
    X.rawAbort(sid, origin);
    assert.strictEqual(X.io().readState(sid).steps.write_code.status, "in_progress", "fixture readable");
    const r = promptHook(sid);
    assert.strictEqual(r.json.blocks, undefined, r.show);
    assert.strictEqual(r.json.systemMessage, undefined, r.show);
    assert.strictEqual((r.json.hookSpecificOutput || {}).additionalContext, undefined, r.show);
  });
}
caseEnd();
