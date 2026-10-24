"use strict";
// Tests: hooks/lib/hook-cancel-notice.js, hooks/user-prompt-submit-mechanism-check.js
// Tags: TL1, TL2, hooks, pretooluse, userpromptsubmit, hook-cancel, transcript, notice, scope:issue-specific
// #2676 Step 7: a PreToolUse hook that Claude Code cancelled at its timeout leaves a
// hook_cancelled record in the transcript; the next user turn tells the user and the session
// once that the hook's permission decision was lost.
// TL3 gap (what this test does NOT catch):
// - that Claude Code still writes the record in this shape (the transcript is not a contract)
// Closest-to-action mitigation: tests/hooks/TL3-hook-timeout-window.sh.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const fx = require("./feature-2676-hook-cancel-notice/transcript");
const REPO = path.resolve(__dirname, "..", "..");
const LIB = path.join(REPO, "hooks", "lib", "hook-cancel-notice.js");
const HOOK = path.join(REPO, "hooks", "user-prompt-submit-mechanism-check.js");
const work = fs.mkdtempSync(path.join(os.tmpdir(), "f2676-cancel-"));
after(() => { fs.rmSync(work, { recursive: true, force: true }); restore(); });

function loadLib() {
  let lib = null;
  let failure = null;
  try { lib = require(LIB); } catch (error) { failure = error; }
  assert.ok(lib, `hooks/lib/hook-cancel-notice.js loads (${failure && failure.message})`);
  return lib;
}
// The plan names the values (hook name, tool name), not the property names; accept either spelling.
const field = (cancel, names) => names.map((name) => cancel[name]).find((value) => typeof value === "string");
const hookOf = (cancel) => field(cancel, ["hook", "hookName"]);
const toolOf = (cancel) => field(cancel, ["tool", "toolName"]);
const detect = (lines, cursor = 0) => {
  const found = loadLib().detectCancels(lines, cursor);
  assert.ok(Array.isArray(found), `detectCancels returns an array: ${JSON.stringify(found)}`);
  return found;
};

caseBegin("detect-and-build", "hooks/lib/hook-cancel-notice.js");
test("detectCancels: a merged allow-deny hook cancel yields its name with the matcher group, and the tool", () => {
  const found = detect(fx.toLines([fx.userPrompt("run it"), fx.cancelRecord(fx.MERGED_COMMAND), fx.toolResult()]));
  assert.strictEqual(found.length, 1, JSON.stringify(found));
  assert.match(hookOf(found[0]) || "", /^merged-allow-deny(\.js)?\b.*\bbash\b/, JSON.stringify(found[0]));
  assert.strictEqual(toolOf(found[0]), "Bash");
});

test("detectCancels: a single-entry hook cancel yields the command's basename", () => {
  const found = detect(fx.toLines([fx.cancelRecord(fx.SINGLE_COMMAND, "Edit")]));
  assert.strictEqual(found.length, 1, JSON.stringify(found));
  assert.match(hookOf(found[0]) || "", /^scan-outbound(\.js)?$/);
  assert.strictEqual(toolOf(found[0]), "Edit");
});

test("detectCancels: a cancel with a launch prefix (sleep; node ...) yields the hook script's basename", () => {
  const found = detect(fx.toLines([fx.cancelRecord(fx.LAUNCH_DELAY_COMMAND)]));
  assert.strictEqual(found.length, 1, JSON.stringify(found));
  assert.match(hookOf(found[0]) || "", /^block-dotenv(\.js)?$/);
  assert.strictEqual(toolOf(found[0]), "Bash");
});

test("detectCancels: look-alike lines, broken lines and an empty transcript yield nothing", () => {
  assert.deepStrictEqual(detect(fx.toLines(fx.lookalikes())), []);
  assert.deepStrictEqual(detect(fx.BROKEN), []);
  assert.deepStrictEqual(detect([]), []);
});

test("detectCancels: a broken line does not hide the cancel after it", () => {
  const found = detect(fx.BROKEN.concat(fx.toLines([fx.cancelRecord(fx.SINGLE_COMMAND)])));
  assert.strictEqual(found.length, 1, JSON.stringify(found));
});

test("detectCancels: cancels before the cursor are not returned", () => {
  const lines = fx.toLines([fx.cancelRecord(fx.SINGLE_COMMAND), fx.userPrompt("a"), fx.userPrompt("b"),
    fx.userPrompt("c"), fx.cancelRecord(fx.MERGED_COMMAND)]);
  assert.strictEqual(detect(lines, 0).length, 2, "cursor 0 reads everything");
  const after2 = detect(lines, 2);
  assert.strictEqual(after2.length, 1, JSON.stringify(after2));
  assert.match(hookOf(after2[0]) || "", /merged-allow-deny/);
  assert.deepStrictEqual(detect(lines, lines.length), [], "a cursor at the end returns nothing");
});

test("buildCancelNotice: a user text and a session text, both naming the cancelled hook and tool", () => {
  const lib = loadLib();
  const cancels = detect(fx.toLines([fx.cancelRecord(fx.MERGED_COMMAND)]));
  const notice = lib.buildCancelNotice(cancels);
  const texts = Object.values(notice || {}).filter((value) => typeof value === "string" && value !== "");
  assert.ok(texts.length >= 2, `a user text and a session text: ${JSON.stringify(notice)}`);
  for (const text of texts) {
    assert.match(text, /merged-allow-deny/, `names the hook: ${text}`);
    assert.match(text, /Bash/, `names the tool: ${text}`);
  }
});
caseEnd();

// runPromptHook(transcriptPath, sid) -> parsed stdout of the UserPromptSubmit hook, run as a
// process. Each case has its own session, since the read position is kept per session.
function runPromptHook(transcriptPath, sid) {
  const env = { ...process.env, CLAUDE_TRANSCRIPT_BASE_DIR: path.join(work, "no-transcripts") };
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  fs.mkdirSync(env.CLAUDE_TRANSCRIPT_BASE_DIR, { recursive: true });
  const done = childProcess.spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ session_id: sid, transcript_path: transcriptPath, hook_event_name: "UserPromptSubmit", prompt: "next" }),
    env, cwd: work, encoding: "utf8", timeout: 60000,
  });
  assert.strictEqual(done.status, 0, `hook exits 0 (stderr: ${done.stderr})`);
  return JSON.parse(done.stdout || "{}");
}
const contextOf = (output) => String((output.hookSpecificOutput || {}).additionalContext || "");
function writeTranscript(name, records) {
  const file = path.join(work, name);
  fs.writeFileSync(file, fx.toText(records));
  return file;
}

caseBegin("prompt-hook-notice", "hooks/user-prompt-submit-mechanism-check.js");
test("regression: a transcript without cancels keeps today's empty output", () => {
  assert.deepStrictEqual(runPromptHook(writeTranscript("quiet.jsonl", [fx.userPrompt("hi"), fx.toolResult()]), "f2676-quiet"), {});
});

test("regression: an unreadable transcript keeps today's empty output", () => {
  assert.deepStrictEqual(runPromptHook(path.join(work, "missing", "none.jsonl"), "f2676-missing"), {});
  assert.deepStrictEqual(runPromptHook(work, "f2676-directory"), {}, "a directory in place of the transcript");
});

test("a cancel in the transcript reaches systemMessage and additionalContext, once", () => {
  const file = writeTranscript("cancel.jsonl", [fx.userPrompt("run"), fx.cancelRecord(fx.MERGED_COMMAND), fx.toolResult()]);
  const first = runPromptHook(file, fx.SESSION);
  assert.match(String(first.systemMessage || ""), /merged-allow-deny/, `user notice: ${JSON.stringify(first)}`);
  assert.match(contextOf(first), /merged-allow-deny/, `session notice: ${JSON.stringify(first)}`);
  assert.strictEqual((first.hookSpecificOutput || {}).hookEventName, "UserPromptSubmit");
  const second = runPromptHook(file, fx.SESSION);
  assert.doesNotMatch(JSON.stringify(second), /merged-allow-deny/, `no second notice: ${JSON.stringify(second)}`);
  // A cancel written after the first notice is new and is told.
  fs.appendFileSync(file, fx.toText([fx.userPrompt("again"), fx.cancelRecord(fx.SINGLE_COMMAND)]));
  const third = runPromptHook(file, fx.SESSION);
  assert.match(String(third.systemMessage || ""), /scan-outbound/, `new cancel told: ${JSON.stringify(third)}`);
  assert.doesNotMatch(String(third.systemMessage || ""), /merged-allow-deny/, "the old cancel is not told again");
});

// Launch delay (TL3 A4): a cancel caused by a delay before the hook's own node starts is recorded
// the same way, so its outcome is deterministic here: one notice naming the hook script, not the
// prefix. When Claude Code starts its clock is not decided by this file (TL3 observes it only).
test("a launch-delay cancel reaches systemMessage and additionalContext naming the hook, once", () => {
  const file = writeTranscript("launch-delay.jsonl", [fx.userPrompt("run"), fx.cancelRecord(fx.LAUNCH_DELAY_COMMAND), fx.toolResult()]);
  const sessionId = "00000000-0000-4000-8000-0000000026a4";
  const first = runPromptHook(file, sessionId);
  assert.match(String(first.systemMessage || ""), /block-dotenv/, `user notice: ${JSON.stringify(first)}`);
  assert.match(contextOf(first), /block-dotenv/, `session notice: ${JSON.stringify(first)}`);
  assert.doesNotMatch(String(first.systemMessage || ""), /\bsleep\b/, "the launch prefix is not taken for the hook name");
  const second = runPromptHook(file, sessionId);
  assert.doesNotMatch(JSON.stringify(second), /block-dotenv/, `no second notice: ${JSON.stringify(second)}`);
});
caseEnd();
