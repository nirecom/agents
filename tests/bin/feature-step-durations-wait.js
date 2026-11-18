"use strict";
// Tests: bin/step-durations/sources.js
// Tags: step-durations, transcript, wait, sentinel, meta-resume, TL2, scope:common
// TL3 gap (what this test does NOT catch):
// - record shapes of transcripts written by a real Claude Code session beyond the fixture subset
// Closest-to-action mitigation: manual reconciliation against real transcripts (detail plan step 6).
const { caseBegin, caseEnd } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const cp = require("node:child_process");

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "step-dur-wait-"));
const HOME_DIR = path.join(ROOT, "home");
const STATE_DIR = path.join(ROOT, "workflow");
const PLANS_DIR = path.join(ROOT, "plans");
const BASE_DIR = path.join(ROOT, "projects");
const PROJ_DIR = path.join(BASE_DIR, "c--fixture-repo");
for (const d of [HOME_DIR, STATE_DIR, PLANS_DIR, PROJ_DIR]) fs.mkdirSync(d, { recursive: true });
after(() => { fs.rmSync(ROOT, { recursive: true, force: true }); });

const CLI = path.join(__dirname, "../../bin/step-durations.js");
const ENV = Object.assign({}, process.env, {
  HOME: HOME_DIR, USERPROFILE: HOME_DIR, WORKFLOW_STATE_DIR: STATE_DIR,
  WORKFLOW_PLANS_DIR: PLANS_DIR, CLAUDE_TRANSCRIPT_BASE_DIR: BASE_DIR,
});
delete ENV.CLAUDE_CODE_SESSION_ID;

const T = (hm) => `2026-05-15T${hm}:00.000Z`;
const user = (hm, content, extra) => Object.assign({ type: "user", timestamp: T(hm), message: { role: "user", content } }, extra);
const asstText = (hm, text) => ({ type: "assistant", timestamp: T(hm), message: { role: "assistant", content: [{ type: "text", text }] } });
const asstTool = (hm, name, id, input) => ({ type: "assistant", timestamp: T(hm), message: { role: "assistant", content: [{ type: "tool_use", id, name, input }] } });
const toolResult = (hm, id) => user(hm, [{ type: "tool_result", tool_use_id: id, content: "ok" }]);
const stopHook = (hm) => ({ type: "system", subtype: "stop_hook_summary", timestamp: T(hm), isSidechain: false });
const sentinelBash = (hm, id) => asstTool(hm, "Bash", id, { command: 'echo "<<WORKFLOW_CONFIRM_OUTLINE: ok>>"' });
const peerMeta = (hm) => user(hm, "Another Claude session sent a message: hi", { isMeta: true, origin: { kind: "peer" } });

// Every session: start 12:00, make-outline-plan Skill 12:05, last assistant text 13:00 (60 min).
function build(mid, tail) {
  return [
    user("12:00", "start the task"),
    asstTool("12:05", "Skill", "s1", { skill: "make-outline-plan" }),
    ...mid,
    asstText("13:00", "done"),
    ...(tail || []),
  ];
}

// expect = wall/span/wait/net as the CLI prints them.
const ROWS = {
  sentinel: { sid: "e0000001", expect: "60.0/60.0/30.0/30.0", mid: [sentinelBash("12:10", "b1"), toolResult("12:40", "b1")] },
  metaResume: { sid: "f0000001", expect: "60.0/60.0/30.0/30.0", mid: [asstText("12:10", "waiting"), stopHook("12:11"), peerMeta("12:41")] },
  taskNotification: {
    sid: "a0000001", expect: "60.0/60.0/0.0/60.0",
    mid: [
      stopHook("12:11"),
      user("12:41", "<system-reminder><tools-used-before-summary>x</tools-used-before-summary></system-reminder>", { isMeta: true, turnCompanion: true }),
      user("12:41", "<task-notification>done</task-notification>", { origin: { kind: "task-notification" } }),
    ],
  },
  legacyTaskNotification: {
    sid: "a0000002", expect: "60.0/60.0/0.0/60.0",
    mid: [stopHook("12:11"), user("12:41", "<task-notification>done</task-notification>", { isMeta: true })],
  },
  human: { sid: "b0000001", expect: "60.0/60.0/31.0/29.0", mid: [asstText("12:10", "waiting"), stopHook("12:11"), user("12:41", "please continue")] },
  overlap: {
    sid: "c0000001", expect: "60.0/60.0/30.0/30.0",
    mid: [
      asstTool("12:10", "AskUserQuestion", "q1", { questions: [] }), sentinelBash("12:20", "b2"),
      toolResult("12:30", "q1"), toolResult("12:40", "b2"),
    ],
  },
  nonSentinel: { sid: "d0000001", expect: "60.0/60.0/0.0/60.0", mid: [asstTool("12:10", "Bash", "b3", { command: "npm test" }), toolResult("12:40", "b3")] },
  malformed: {
    sid: "d0000002", expect: "60.0/60.0/0.0/60.0",
    mid: [
      "{this is not json",
      asstTool("12:10", "Bash", "n1", { command: null }),
      toolResult("12:11", "n1"),
      sentinelBash("12:15", "orphan"),
      peerMeta("12:20"),
    ],
    tail: [stopHook("13:00")],
  },
  stopTsReset: { sid: "a1000001", expect: "60.0/60.0/0.0/60.0", mid: [stopHook("12:11"), asstText("12:15", "more"), peerMeta("12:41")] },
  consecutiveStops: { sid: "a1000002", expect: "60.0/60.0/30.0/30.0", mid: [stopHook("12:11"), stopHook("12:20"), peerMeta("12:41")] },
  nonBashSentinel: {
    sid: "a1000003", expect: "60.0/60.0/0.0/60.0",
    mid: [asstTool("12:10", "PowerShell", "p1", { command: "<<WORKFLOW_CONFIRM_OUTLINE: ok>>" }), toolResult("12:40", "p1")],
  },
  genericMeta: {
    sid: "a1000004", expect: "60.0/60.0/30.0/30.0",
    mid: [stopHook("12:11"), user("12:41", "<local-command-caveat>x</local-command-caveat>", { isMeta: true })],
  },
  queueMetaResume: {
    sid: "a1000005", expect: "60.0/60.0/30.0/30.0",
    mid: [
      asstText("12:10", "waiting"), stopHook("12:11"),
      { type: "queue-operation", operation: "enqueue", timestamp: T("12:40") },
      { type: "queue-operation", operation: "dequeue", timestamp: T("12:41") },
      { type: "attachment", timestamp: T("12:41") },
      peerMeta("12:41"),
    ],
  },
  originOnlyTaskNotification: {
    sid: "a1000006", expect: "60.0/60.0/0.0/60.0",
    mid: [stopHook("12:11"), user("12:41", "done", { isMeta: true, origin: { kind: "task-notification" } })],
  },
  humanResetsStop: {
    sid: "a1000007", expect: "60.0/60.0/31.0/29.0",
    mid: [asstText("12:10", "waiting"), stopHook("12:11"), user("12:41", "please continue"), peerMeta("12:50")],
  },
  notHumanResetsStop: {
    sid: "a1000008", expect: "60.0/60.0/0.0/60.0",
    mid: [stopHook("12:11"), user("12:30", "Stop hook feedback: x"), peerMeta("12:41")],
  },
  metaResumeClearsStop: {
    sid: "a100000a", expect: "60.0/60.0/30.0/30.0",
    mid: [asstText("12:10", "waiting"), stopHook("12:11"), peerMeta("12:41"), peerMeta("12:50")],
  },
  nonStopSystemRecord: {
    sid: "a100000b", expect: "60.0/60.0/0.0/60.0",
    mid: [asstText("12:10", "waiting"), { type: "system", subtype: "turn_duration", timestamp: T("12:11"), isSidechain: false }, peerMeta("12:41")],
  },
  sidechainStop: {
    sid: "a100000c", expect: "60.0/60.0/0.0/60.0",
    mid: [asstText("12:10", "waiting"), Object.assign(stopHook("12:11"), { isSidechain: true }), peerMeta("12:41")],
  },
  sidechainSentinel: {
    sid: "a100000d", expect: "60.0/60.0/0.0/60.0",
    mid: [
      Object.assign(sentinelBash("12:10", "sb"), { isSidechain: true }),
      Object.assign(toolResult("12:40", "sb"), { isSidechain: true }),
    ],
  },
  taskNotificationKeepsStop: {
    sid: "a1000009", expect: "60.0/60.0/30.0/30.0",
    mid: [stopHook("12:11"), user("12:20", "done", { isMeta: true, origin: { kind: "task-notification" } }), peerMeta("12:41")],
  },
};

function sessionRow(row) {
  const sid = `${row.sid}-1111-2222-3333-444444444444`;
  const lines = build(row.mid, row.tail).map((r) => (typeof r === "string" ? r : JSON.stringify(r)));
  fs.writeFileSync(path.join(PROJ_DIR, `${sid}.jsonl`), lines.join("\n") + "\n");
  const r = cp.spawnSync(process.execPath, [CLI, "--format", "csv", "--since", "2026-05-01", "--until", "2026-05-31", "--session", row.sid], {
    env: ENV, cwd: ROOT, encoding: "utf8", timeout: 60000,
  });
  assert.strictEqual(r.status, 0, `exit ${r.status}: ${r.stderr}`);
  const found = r.stdout.split(/\r?\n/).filter((l) => l.startsWith("session,"));
  assert.strictEqual(found.length, 1, `expected one session row, got:\n${r.stdout}`);
  const f = found[0].split(",");
  return `${f[7]}/${f[8]}/${f[9]}/${f[10]}`;
}

const check = (key) => assert.strictEqual(sessionRow(ROWS[key]), ROWS[key].expect);

caseBegin("sentinel-bash-wait-counts", "bin/step-durations/sources.js");
test("a Bash sentinel awaiting its tool_result counts as a user wait", () => check("sentinel"));
caseEnd();

caseBegin("meta-peer-resume-wait-counts", "bin/step-durations/sources.js");
test("an isMeta peer message after a stop_hook_summary ends a user wait", () => check("metaResume"));
caseEnd();

caseBegin("notification-of-task-not-a-wait", "bin/step-durations/sources.js");
test("a non-meta task-notification text record after a turn companion is no user wait (NOT_HUMAN exclusion)", () => check("taskNotification"));
caseEnd();

caseBegin("legacy-notification-of-task-not-a-wait", "bin/step-durations/sources.js");
test("a legacy isMeta task-notification without origin is no user wait", () => check("legacyTaskNotification"));
caseEnd();

caseBegin("human-prompt-wait-unchanged", "bin/step-durations/sources.js");
test("a human prompt still waits from the last assistant record; system record does not move the start", () => check("human"));
caseEnd();

caseBegin("overlapping-waits-union", "bin/step-durations/sources.js");
test("AskUserQuestion and sentinel waits overlapping are counted once", () => check("overlap"));
caseEnd();

caseBegin("non-sentinel-bash-no-wait", "bin/step-durations/sources.js");
test("a long non-sentinel Bash tool call adds no wait (pre-change behavior)", () => check("nonSentinel"));
caseEnd();

caseBegin("malformed-records-tolerated", "bin/step-durations/sources.js");
test("broken JSON, null command, orphan sentinel, unanchored meta and trailing stop hook do not crash or add wait", () => check("malformed"));
caseEnd();

caseBegin("stop-ts-reset-by-assistant-record", "bin/step-durations/sources.js");
test("an assistant record after a stop_hook_summary resets the start, so a later peer resume has no open stop", () => check("stopTsReset"));
caseEnd();

caseBegin("consecutive-stop-hooks-keep-first", "bin/step-durations/sources.js");
test("consecutive stop_hook_summary records keep the first time as the wait start", () => check("consecutiveStops"));
caseEnd();

caseBegin("non-bash-tool-sentinel-no-wait", "bin/step-durations/sources.js");
test("a sentinel carried by a non-Bash tool (PowerShell) adds no wait", () => check("nonBashSentinel"));
caseEnd();

caseBegin("generic-meta-resume-counts-as-wait", "bin/step-durations/sources.js");
test("an isMeta record without origin and not a task-notification after a stop hook counts as a wait", () => check("genericMeta"));
caseEnd();

caseBegin("queue-operation-records-keep-stop-window", "bin/step-durations/sources.js");
test("queue-operation and attachment records between a stop hook and a meta peer resume do not reset the stop window", () => check("queueMetaResume"));
caseEnd();

caseBegin("origin-only-notification-of-task-not-a-wait", "bin/step-durations/sources.js");
test("an isMeta record with origin kind task-notification and plain text content is no user wait", () => check("originOnlyTaskNotification"));
caseEnd();

caseBegin("human-prompt-resets-stop-window", "bin/step-durations/sources.js");
test("a human prompt after a stop hook clears the stop window, so a later peer resume adds no second wait", () => check("humanResetsStop"));
caseEnd();

caseBegin("non-human-user-text-resets-stop-window", "bin/step-durations/sources.js");
test("a non-meta Stop hook feedback user record clears the stop window", () => check("notHumanResetsStop"));
caseEnd();

caseBegin("meta-resume-clears-stop-window", "bin/step-durations/sources.js");
test("a meta resume clears the stop window, so a second peer message adds no wait", () => check("metaResumeClearsStop"));
caseEnd();

caseBegin("non-stop-system-record-no-stop-window", "bin/step-durations/sources.js");
test("a system record other than stop_hook_summary opens no stop window", () => check("nonStopSystemRecord"));
caseEnd();

caseBegin("sidechain-stop-hook-ignored", "bin/step-durations/sources.js");
test("a sidechain stop_hook_summary opens no stop window", () => check("sidechainStop"));
caseEnd();

caseBegin("sidechain-sentinel-ignored", "bin/step-durations/sources.js");
test("a sentinel Bash call inside a sidechain adds no wait", () => check("sidechainSentinel"));
caseEnd();

caseBegin("notification-of-task-keeps-stop-window", "bin/step-durations/sources.js");
test("an isMeta task-notification between a stop hook and a peer resume keeps the stop window open", () => check("taskNotificationKeepsStop"));
caseEnd();
