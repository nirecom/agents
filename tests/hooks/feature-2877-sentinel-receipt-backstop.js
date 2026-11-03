"use strict";
// Tests: hooks/lib/sentinel-receipt.js, hooks/workflow-mark.js, hooks/stop-sentinel-unapplied-notice.js, hooks/stop-sentinel-unapplied-notice/scan.js, settings.json
// Tags: TL2, hooks, stop, posttooluse, sentinel, transcript, notice, scope:issue-specific
// #2877 / #2824 Step 3: workflow-mark.js appends a sentinel receipt and its outcome; at Stop the
// backstop tells the user, once, about a sentinel of this turn that was never applied: a
// PostToolUse cancel -> timeout, no receipt -> never reached (or no session), receipt without an
// outcome -> stopped mid-way. A tool_result with is_error (PreToolUse / permission deny) is skipped.
// TL3 gap (what this test does NOT catch):
// - that Claude Code still writes tool_result.is_error and the PostToolUse hook_cancelled record
//   in these shapes (the transcript is not a contract), and that the registered Stop hook fires in
//   the real host (the registration entry itself is read from settings.json below).
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
// lang-check: ignore — the regexes below match the Japanese output of the hook under test.

const assert = require("node:assert");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const X = require("./feature-2824-sentinel-refusal-output/fixture").make();
const T = require("./feature-2877-sentinel-receipt-backstop/transcript");
const ROOT = path.resolve(__dirname, "..", "..");
const RECEIPT_LIB = path.join(ROOT, "hooks", "lib", "sentinel-receipt.js");
const STOP_HOOK = path.join(ROOT, "hooks", "stop-sentinel-unapplied-notice.js");
const TX = path.join(X.TMP, "tx");
fs.mkdirSync(TX);
after(() => { X.cleanup(); restore(); });

// Message classes. The wording is the implementer's; each class needs one recognisable phrase.
const TIMEOUT = /time[ds]? ?out|timeout|タイムアウト/i;
const UNREACHED = /(did not|never|not) reach|unreached|届かな|未到達|could not (resolve|record)/i;
const MIDWAY = /mid-?way|part-?way|stopped (in|during|before)|did not (finish|complete)|途中/i;

function loadReceipt() {
  let lib = null;
  try { lib = require(RECEIPT_LIB); } catch (e) {
    throw new Error(`not implemented: hooks/lib/sentinel-receipt.js does not load (${String(e.message).split("\n")[0]})`);
  }
  return lib;
}

// runStop(sid, transcriptPath) -> {code, out, stdout}; out is the parsed stdout ({} when empty).
function runStop(sid, transcriptPath) {
  if (!fs.existsSync(STOP_HOOK)) throw new Error("not implemented: hooks/stop-sentinel-unapplied-notice.js does not exist");
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  const r = childProcess.spawnSync(process.execPath, [STOP_HOOK], {
    input: JSON.stringify({ session_id: sid, transcript_path: transcriptPath, hook_event_name: "Stop", stop_hook_active: false, cwd: X.REPO }),
    env, cwd: X.REPO, encoding: "utf8", timeout: 60000,
  });
  assert.strictEqual(r.status, 0, `Stop hook exits 0 (stderr: ${r.stderr})`);
  const text = String(r.stdout || "").trim();
  let out = {};
  if (text !== "") out = JSON.parse(text);
  assert.strictEqual(out.decision, undefined, `the backstop never blocks: ${text}`);
  return { code: r.status, out, stdout: text };
}
// The only output field is systemMessage (no new gate, no session-side injection).
function expectNotice(r, pattern, label) {
  assert.deepStrictEqual(Object.keys(r.out), ["systemMessage"], `${label}: systemMessage only: ${r.stdout}`);
  assert.match(r.out.systemMessage, pattern, `${label}: ${r.out.systemMessage}`);
  assert.match(r.out.systemMessage, /research/, `${label}: names the sentinel: ${r.out.systemMessage}`);
  return r.out.systemMessage;
}
const expectQuiet = (r, label) => assert.ok(!r.out.systemMessage, `${label}: no notice: ${r.stdout}`);

let txn = 0;
function writeTx(sid, records) {
  const file = path.join(TX, `t${++txn}.jsonl`);
  fs.writeFileSync(file, T.toText(records));
  return file;
}
// turn(sid, body) -> a transcript of one turn: prompt, body records, closing assistant text.
const turn = (sid, body) => writeTx(sid, [T.userPrompt(sid, "go"), ...body, T.assistantText(sid, "done")]);
const receipt = (sid, id, applied) => {
  const lib = loadReceipt();
  lib.recordReceipt(sid, id, [T.SENTINEL]);
  if (applied) lib.recordOutcome(sid, id, { applied: [T.SENTINEL], unapplied: [] });
};

caseBegin("receipt", "hooks/lib/sentinel-receipt.js");
test("sentinel-receipt exports recordReceipt and recordOutcome", () => {
  const lib = loadReceipt();
  assert.strictEqual(typeof lib.recordReceipt, "function");
  assert.strictEqual(typeof lib.recordOutcome, "function");
});

test("workflow-mark.js appends a receipt and an outcome under the session control dir", () => {
  loadReceipt();
  const sid = X.seedInit("rc");
  const id = "toolu_f2877_receipt";
  X.mark(sid, T.SENTINEL, { toolUseId: id });
  const dir = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`);
  const files = fs.existsSync(dir) ? fs.readdirSync(dir) : [];
  const lines = files.flatMap((f) => fs.readFileSync(path.join(dir, f), "utf8").split("\n")).filter((l) => l.includes(id));
  assert.ok(lines.length >= 2, `a receipt line and an outcome line name ${id}: ${JSON.stringify(files)}`);
});

// receiptKinds(sid, id) -> {receipt, outcome, last} — per-kind line counts for one tool_use id, and its last outcome.
function receiptKinds(sid, id) {
  const file = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`, loadReceipt().RECEIPT_FILE);
  const rows = fs.existsSync(file) ? fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
  const mine = rows.filter((r) => r.tool_use_id === id);
  const outcomes = mine.filter((r) => r.kind === "outcome");
  return { receipt: mine.filter((r) => r.kind === "receipt").length, outcome: outcomes.length, last: outcomes[outcomes.length - 1] };
}

test("a rejected sentinel (unknown step, echo exit 1) gets a receipt and an unapplied outcome; Stop stays quiet", () => {
  const bogus = 'echo "<<WORKFLOW_MARK_STEP_bogus_step_complete>>"';
  for (const [tag, command, opts] of [["rj-step", bogus, {}], ["rj-exit", T.SENTINEL, { exitCode: 1 }]]) {
    const sid = X.seedInit(tag);
    const id = `toolu_f2877_${tag}`;
    X.mark(sid, command, { toolUseId: id, ...opts });
    const k = receiptKinds(sid, id);
    assert.strictEqual(k.receipt, 1, `${tag}: one receipt line`);
    assert.strictEqual(k.outcome, 1, `${tag}: one outcome line`);
    assert.deepStrictEqual(k.last.applied, [], `${tag}: nothing applied`);
    assert.deepStrictEqual(k.last.unapplied, [command], `${tag}: the sentinel is listed unapplied`);
    expectQuiet(runStop(sid, turn(sid, T.call(sid, id, command))), `${tag}: workflow-mark already told it`);
  }
});

test("no receipt is written when the session cannot be resolved", () => {
  loadReceipt();
  const id = "toolu_f2877_nosid";
  X.mark(null, T.SENTINEL, { toolUseId: id, noSession: true });
  const hits = [];
  const walk = (d) => {
    for (const e of fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }) : []) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (fs.readFileSync(p, "utf8").includes(id)) hits.push(p);
    }
  };
  walk(process.env.WORKFLOW_STATE_DIR);
  walk(X.HOME);
  assert.deepStrictEqual(hits, [], "nowhere to write, nothing written");
});
caseEnd();

caseBegin("backstop", "hooks/stop-sentinel-unapplied-notice.js");
test("is_error results are skipped: a PreToolUse deny and a permission deny give no notice", () => {
  const sid = X.seedInit("bs-err");
  const file = turn(sid, [
    ...T.call(sid, "toolu_deny_hook", T.SENTINEL, { isError: true, text: "PreToolUse:Bash hook error: blocked by workflow-gate" }),
    ...T.call(sid, "toolu_deny_perm", T.SENTINEL, { isError: true, text: "The user doesn't want to proceed with this tool use." }),
  ]);
  expectQuiet(runStop(sid, file), "is_error");
});

test("a PostToolUse cancel of the same tool_use is told as a timeout, ahead of the receipt check", () => {
  const sid = X.seedInit("bs-to");
  receipt(sid, "toolu_cancel", false);
  const file = turn(sid, [...T.call(sid, "toolu_cancel", T.SENTINEL), T.postToolUseCancel(sid, "toolu_cancel")]);
  const msg = expectNotice(runStop(sid, file), TIMEOUT, "timeout");
  assert.doesNotMatch(msg, UNREACHED, "not told as never reached");
});

test("a sentinel without a receipt is told as never reached", () => {
  const sid = X.seedInit("bs-nr");
  const msg = expectNotice(runStop(sid, turn(sid, T.call(sid, "toolu_none", T.SENTINEL))), UNREACHED, "no receipt");
  assert.doesNotMatch(msg, TIMEOUT, "not told as a timeout");
});

test("a receipt without an outcome is told as stopped mid-way", () => {
  const sid = X.seedInit("bs-mid");
  receipt(sid, "toolu_mid", false);
  const msg = expectNotice(runStop(sid, turn(sid, T.call(sid, "toolu_mid", T.SENTINEL))), MIDWAY, "no outcome");
  assert.doesNotMatch(msg, TIMEOUT, "not told as a timeout");
});

test("an applied sentinel, a plain command and a previous turn's sentinel give no notice", () => {
  const sid = X.seedInit("bs-ok");
  receipt(sid, "toolu_ok", true);
  const file = writeTx(sid, [
    T.userPrompt(sid, "first"), ...T.call(sid, "toolu_old", T.SENTINEL), T.assistantText(sid, "one"),
    T.userPrompt(sid, "second"), ...T.call(sid, "toolu_ok", T.SENTINEL), ...T.call(sid, "toolu_ls", "ls -la"),
    T.assistantText(sid, "two"),
  ]);
  expectQuiet(runStop(sid, file), "applied / plain / old turn");
});

test("a session without workflow state gets no output", () => {
  const sid = X.nextSid("bs-nostate");
  const r = runStop(sid, turn(sid, T.call(sid, "toolu_nostate", T.SENTINEL)));
  assert.ok(r.stdout === "" || r.stdout === "{}", `no output: ${r.stdout}`);
});

test("a tool_use is told once; a later unapplied sentinel is told on its own", () => {
  const sid = X.seedInit("bs-once");
  const file = turn(sid, T.call(sid, "toolu_once_a", T.SENTINEL));
  expectNotice(runStop(sid, file), UNREACHED, "first stop");
  expectQuiet(runStop(sid, file), "second stop on the same transcript");
  fs.appendFileSync(file, T.toText([T.userPrompt(sid, "again"), ...T.call(sid, "toolu_once_b", T.SENTINEL), T.assistantText(sid, "x")]));
  expectNotice(runStop(sid, file), UNREACHED, "new tool_use");
});

test("a receipt with its outcome gives no notice; the same turn with a receipt only is told mid-way", () => {
  const done = X.seedInit("bs-outcome");
  receipt(done, "toolu_outcome", true);
  expectQuiet(runStop(done, turn(done, T.call(done, "toolu_outcome", T.SENTINEL))), "receipt + outcome");
  const half = X.seedInit("bs-receipt-only");
  receipt(half, "toolu_outcome", false);
  expectNotice(runStop(half, turn(half, T.call(half, "toolu_outcome", T.SENTINEL))), MIDWAY, "receipt only");
});

test("a cancel for another tool_use, from another hook event, or with timedOut false is not told as a timeout", () => {
  for (const [tag, cancel] of [
    ["bs-cancel-id", (sid) => T.postToolUseCancel(sid, "toolu_someone_else")],
    ["bs-cancel-ev", (sid) => T.postToolUseCancel(sid, "toolu_neg", "PreToolUse")],
    ["bs-cancel-int", (sid) => T.postToolUseCancel(sid, "toolu_neg", "PostToolUse", { timedOut: false })],
  ]) {
    const sid = X.seedInit(tag);
    receipt(sid, "toolu_neg", false);
    const msg = expectNotice(runStop(sid, turn(sid, [...T.call(sid, "toolu_neg", T.SENTINEL), cancel(sid)])), MIDWAY, tag);
    assert.doesNotMatch(msg, TIMEOUT, `${tag}: an unrelated cancel is not this sentinel's timeout`);
  }
});

test("several unapplied sentinels in one turn are each told on their own line", () => {
  const sid = X.seedInit("bs-multi");
  const outline = 'echo "<<WORKFLOW_MARK_STEP_outline_complete>>"';
  receipt(sid, "toolu_multi_mid", false);
  const r = runStop(sid, turn(sid, [...T.call(sid, "toolu_multi_nr", outline), ...T.call(sid, "toolu_multi_mid", T.SENTINEL)]));
  const msg = expectNotice(r, UNREACHED, "multi");
  const lines = msg.split("\n");
  assert.strictEqual(lines.length, 3, `a header and one line per sentinel: ${msg}`);
  assert.ok(lines.some((l) => l.includes(outline) && UNREACHED.test(l)), `the outline sentinel is told as never reached: ${msg}`);
  assert.ok(lines.some((l) => l.includes(T.SENTINEL) && MIDWAY.test(l)), `the research sentinel is told mid-way: ${msg}`);
});

test("a command over 160 chars is cut to 157 plus '...'; one of exactly 160 is shown whole", () => {
  const sid = X.seedInit("bs-long");
  const at = (n) => { const head = 'echo "<<WORKFLOW_RESET_FROM_research: '; return `${head}${"r".repeat(n - head.length - 3)}>>"`; };
  const exact = at(160);
  const long = at(161);
  assert.strictEqual(exact.length, 160);
  const msg = expectNotice(runStop(sid, turn(sid, [...T.call(sid, "toolu_long_a", exact), ...T.call(sid, "toolu_long_b", long)])), UNREACHED, "long");
  assert.ok(msg.includes(`\`${exact}\``), `the 160-char command is shown whole: ${msg}`);
  assert.ok(msg.includes(`\`${long.slice(0, 157)}...\``), `the 161-char command is cut: ${msg}`);
  assert.ok(!msg.includes(long), `the 161-char command is not shown whole: ${msg}`);
});
caseEnd();

caseBegin("backstop-fail-open", "hooks/stop-sentinel-unapplied-notice.js");
// runStopRaw(input) — the Stop hook on arbitrary stdin; it must fail open: exit 0, no decision, no notice.
function runStopRaw(input, label) {
  if (!fs.existsSync(STOP_HOOK)) throw new Error("not implemented: hooks/stop-sentinel-unapplied-notice.js does not exist");
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  const r = childProcess.spawnSync(process.execPath, [STOP_HOOK], { input, env, cwd: X.REPO, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `${label}: exit 0 (stderr: ${r.stderr})`);
  const text = String(r.stdout || "").trim();
  let out = {};
  if (text !== "") assert.doesNotThrow(() => { out = JSON.parse(text); }, `${label}: stdout is JSON or empty: ${text}`);
  assert.strictEqual(out.decision, undefined, `${label}: never blocks: ${text}`);
  assert.ok(!out.systemMessage, `${label}: no notice: ${text}`);
}

test("no transcript_path, a missing transcript, broken or empty stdin -> exit 0, no decision, no notice", () => {
  const sid = X.seedInit("bs-failopen");
  const base = { session_id: sid, hook_event_name: "Stop", stop_hook_active: false, cwd: X.REPO };
  runStopRaw(JSON.stringify(base), "no transcript_path");
  runStopRaw(JSON.stringify({ ...base, transcript_path: path.join(TX, "missing.jsonl") }), "missing transcript");
  runStopRaw("{not json", "broken stdin");
  runStopRaw("", "empty stdin");
});
caseEnd();

caseBegin("registration", "settings.json");
// registered(event, hookName) -> every {matcher, command, timeout} of settings.json hooks[event] whose
// command launches hooks/<hookName>.js (the shape of tests/hooks/feature-2676-hook-classification/registration.js).
function registered(event, hookName) {
  const settings = JSON.parse(fs.readFileSync(path.join(ROOT, "settings.json"), "utf8"));
  const found = [];
  for (const group of (settings.hooks && settings.hooks[event]) || []) {
    for (const hook of group.hooks || []) {
      if (String(hook.command || "").includes(`/hooks/${hookName}.js`)) found.push({ matcher: group.matcher, command: hook.command, timeout: hook.timeout });
    }
  }
  return found;
}

test("the backstop is registered once under hooks.Stop, through AGENTS_MAIN_ROOT, with timeout 5", () => {
  const found = registered("Stop", "stop-sentinel-unapplied-notice");
  if (found.length === 0) throw new Error("not implemented: settings.json hooks.Stop has no hooks/stop-sentinel-unapplied-notice.js entry");
  assert.strictEqual(found.length, 1, `exactly one Stop registration: ${JSON.stringify(found)}`);
  assert.strictEqual(found[0].command, 'node "$AGENTS_MAIN_ROOT/hooks/stop-sentinel-unapplied-notice.js"');
  assert.strictEqual(found[0].timeout, 5);
});

// Detail Step 4 H1: the workflow-mark.js PostToolUse timeout goes from 5 to 30 s (same as show-plan-link.js).
test("workflow-mark.js is registered once under hooks.PostToolUse with timeout 30", () => {
  const found = registered("PostToolUse", "workflow-mark");
  assert.strictEqual(found.length, 1, `exactly one PostToolUse registration: ${JSON.stringify(found)}`);
  if (found[0].timeout !== 30) throw new Error(`not implemented: detail Step 4 H1 raises the workflow-mark.js timeout to 30 (settings.json has ${found[0].timeout})`);
});
caseEnd();
