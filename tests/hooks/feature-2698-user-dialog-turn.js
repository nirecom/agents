"use strict";
// Tests: hooks/lib/user-dialog-turn.js
// Tags: TL1, hooks, supervisor, stop-guard, c4, user-dialog-turn, transcript, ask-user-question, scope:issue-specific
// #2698 change 1: the shared "this Stop ends a turn of dialog with the user" predicate, judged by
// turn structure only (wording is never read). classifyUserDialogTurn -> {kind, decidable};
// isUserDialogTurn never throws; countHumanPromptsSince counts human prompts after iso, or null.
// TL3 gap (what this test does NOT catch):
// - the transcript shape (and origin.kind values) a live Claude Code release writes
// Closest-to-action mitigation: feature-2698-c4-user-dialog-exemption.js runs the real C4 and C2
// Stop hooks on the answer-after-Grep, AskUserQuestion and write-tool-after-question turns.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.resolve(__dirname, "..", "..");
const MOD = path.join(REPO, "hooks", "lib", "user-dialog-turn.js");
const restore = isolate();
process.env.CONV_LANG = "english";
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2698-udt-"));
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

let M = null;
let loadError = null;
try { M = require(MOD); } catch (e) { loadError = e; }
const mod = () => {
  assert.ok(M, `hooks/lib/user-dialog-turn.js loads (${loadError && loadError.message})`);
  return M;
};

const U = (text, extra = {}) => ({ type: "user", message: { role: "user", content: text }, ...extra });
const R = () => ({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } });
const A = (...content) => ({ type: "assistant", message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
const TU = (name, input = {}) => ({ type: "tool_use", id: "t1", name, input });
const HUMAN = { origin: { kind: "human" } };
const NOTIFY = { origin: { kind: "task-notification" } };

let seq = 0;
// scene(entries, lam) -> Stop input; lam defaults to the last text block so the flush settles.
function scene(entries, lam) {
  const p = path.join(ROOT, `t-${++seq}.jsonl`);
  fs.writeFileSync(p, entries.map((e) => (typeof e === "string" ? e : JSON.stringify(e))).join("\n") + "\n");
  let last = null;
  for (const e of entries) {
    if (e && e.type === "assistant") for (const c of e.message.content) if (c.type === "text") last = c.text;
  }
  return { session_id: "udt", transcript_path: p, hook_event_name: "Stop", last_assistant_message: lam === undefined ? last : lam };
}
const kindOf = (input) => mod().classifyUserDialogTurn(input);
const answering = { kind: "answering-user-prompt", decidable: true };
const none = { kind: null, decidable: true };

// The four texts that differ only in wording: a statement, an English question, a Japanese
// question (\u-escaped so no CJK sits in this source), and whitespace only. uesc decodes the
// \u escapes, written with a doubled backslash, through JSON.parse.
const uesc = (s) => JSON.parse(`"${s}"`);
const TEXTS = [
  ["english statement", "It is called from line 12 of hooks/a.js."],
  ["english question", "Which file should I look at next?"],
  ["japanese question", uesc("\\u3053\\u308c\\u306f\\u3069\\u3053\\u3067\\u4f7f\\u308f\\u308c\\u307e\\u3059\\u304b\\uff1f")],
  ["whitespace only", "   "],
];

caseBegin("no-wording-judgment", "hooks/lib/user-dialog-turn.js");
test("exports are exactly the four structural names; no regex, no old name", () => {
  const m = mod();
  assert.deepStrictEqual(Object.keys(m).sort(),
    ["READ_ONLY_TOOL_NAMES", "classifyUserDialogTurn", "countHumanPromptsSince", "isUserDialogTurn"]);
  assert.ok(!("countRealUserPromptsSince" in m), "the old name countRealUserPromptsSince is not exported");
  for (const [k, v] of Object.entries(m)) {
    assert.ok(!(v instanceof RegExp), `${k} is not a RegExp`);
    assert.ok(!/_RE$/.test(k), `${k} is not a *_RE name`);
  }
});
test("READ_ONLY_TOOL_NAMES is exactly the four read-only tools and frozen", () => {
  const m = mod();
  assert.deepStrictEqual([...m.READ_ONLY_TOOL_NAMES].sort(), ["Glob", "Grep", "Read", "mcp__codegraph__codegraph_explore"]);
  assert.ok(Object.isFrozen(m.READ_ONLY_TOOL_NAMES), "READ_ONLY_TOOL_NAMES is frozen");
});
test("the module source carries no CJK character and no lang-check exemption marker", () => {
  const src = fs.readFileSync(MOD, "utf8");
  const CJK = new RegExp("[\\u3000-\\u303F\\u3040-\\u30FF\\u3400-\\u9FFF\\uFF00-\\uFFEF]");
  const hit = src.match(CJK);
  assert.ok(!hit, `no CJK character in the module source (found ${hit && JSON.stringify(hit[0])})`);
  const marker = "lang-check" + ": ignore";
  assert.ok(!src.includes(marker), "the module source carries no lang-check exemption marker");
});
caseEnd();

caseBegin("dialog-kinds-positive", "hooks/lib/user-dialog-turn.js");
test("ask-user-question-tool: AskUserQuestion is the last tool_use (#2698 / #1919)", () => {
  const r = kindOf(scene([U("go"), A(T("Which one?"), TU("AskUserQuestion", { questions: [] }))], ""));
  assert.deepStrictEqual(r, { kind: "ask-user-question-tool", decidable: true });
});
test("answering-user-prompt: a human prompt answered with text only", () => {
  assert.deepStrictEqual(kindOf(scene([U("Where is this function called from?"), A(T("It is called from line 12 of hooks/a.js."))])), answering);
});
for (const tool of ["Read", "Grep", "Glob", "mcp__codegraph__codegraph_explore"]) {
  test(`answering-user-prompt: ${tool} then a text answer (#1919)`, () => {
    const r = kindOf(scene([U("How does readTurnTail work?"), A(TU(tool)), R(), A(T("It reads the transcript tail."))]));
    assert.deepStrictEqual(r, answering);
  });
}
test("answering-user-prompt: Read, Grep, Glob and codegraph together then a text answer", () => {
  const r = kindOf(scene([U("What does readTurnTail return?"), A(TU("Read")), R(), A(TU("Grep")), R(), A(TU("Glob")), R(),
    A(TU("mcp__codegraph__codegraph_explore", { query: "readTurnTail" })), R(), A(T("It returns lines and the tail."))]));
  assert.deepStrictEqual(r, answering);
});
test("answering-user-prompt: an array-content prompt (image + text) opens the turn", () => {
  const prompt = U([{ type: "image", source: { type: "base64", media_type: "image/png", data: "" } }, T("What is this?")]);
  assert.deepStrictEqual(kindOf(scene([prompt, A(T("It is a diagram of the hook chain."))])), answering);
});
test("answering-user-prompt: a prompt with origin {kind: human} and one with no origin", () => {
  assert.deepStrictEqual(kindOf(scene([U("Where is it called from?", HUMAN), A(T("From hooks/a.js."))])), answering);
  assert.deepStrictEqual(kindOf(scene([U("Where is it called from?"), A(T("From hooks/a.js."))])), answering);
});
test("isUserDialogTurn is true for each positive kind", () => {
  assert.strictEqual(mod().isUserDialogTurn(scene([U("go"), A(T("Q"), TU("AskUserQuestion"))], "")), true);
  assert.strictEqual(mod().isUserDialogTurn(scene([U("Where is it called from?"), A(T("From hooks/a.js."))])), true);
});
caseEnd();

caseBegin("text-content-is-never-read", "hooks/lib/user-dialog-turn.js");
for (const [label, text] of TEXTS) {
  test(`positive structure (human prompt + read-only tools + text) with ${label} final text -> answering-user-prompt`, () => {
    assert.deepStrictEqual(kindOf(scene([U("Look into it.", HUMAN), A(TU("Grep")), R(), A(T(text))])), answering);
  });
  test(`negative structure (human prompt + Write + text) with ${label} final text -> kind null`, () => {
    assert.deepStrictEqual(kindOf(scene([U("Look into it.", HUMAN), A(TU("Write", { file_path: "a.js" })), R(), A(T(text))])), none);
  });
  test(`negative structure (human prompt + Write + text) with ${label} prompt text -> kind null`, () => {
    assert.deepStrictEqual(kindOf(scene([U(text, HUMAN), A(TU("Write", { file_path: "a.js" })), R(), A(T("I wrote a.js."))])), none);
  });
}
caseEnd();

caseBegin("dialog-kinds-negative", "hooks/lib/user-dialog-turn.js");
for (const tool of ["Write", "Edit", "Bash", "Skill", "Agent", "SomeUnknownTool"]) {
  test(`a ${tool} tool_use in the turn -> kind null, even when the final text ends in ?`, () => {
    const r = kindOf(scene([U("Why does it fail?"), A(TU(tool)), R(), A(T("Which file should I look at?"))]));
    assert.deepStrictEqual(r, none);
  });
}
test("the last entry carries a tool_use (not AskUserQuestion) -> kind null", () => {
  assert.deepStrictEqual(kindOf(scene([U("Why does it fail?"), A(T("Let me check?"), TU("Read"))])), none);
});
test("the last entry has no text item (thinking only) -> kind null", () => {
  const r = kindOf(scene([U("Why does it fail?"), A(TU("Read")), R(), A({ type: "thinking", thinking: "Still looking." })]));
  assert.deepStrictEqual(r, none);
});
for (const [label, extra] of [["task-notification", NOTIFY], ["an unknown kind", { origin: { kind: "some-future-kind" } }]]) {
  test(`the turn is opened by an origin ${label} user line -> kind null`, () => {
    const r = kindOf(scene([U("<task-notification>run done</task-notification>", extra), A(TU("Read")), R(), A(T("The task finished."))]));
    assert.deepStrictEqual(r, none);
  });
}
test("no human prompt in the transcript (only tool_result and isMeta user lines) -> kind null", () => {
  const r = kindOf(scene([R(), U("hook feedback", { isMeta: true }), A(T("Done."))]));
  assert.deepStrictEqual(r, none);
});
test("an isMeta line after a Write turn does not open a turn: read-only + text after it -> kind null", () => {
  const r = kindOf(scene([U("Fix a.js."), A(TU("Write", { file_path: "a.js" })), R(),
    U("Stop hook feedback: keep going.", { isMeta: true }), A(TU("Read")), R(), A(T("I fixed a.js."))]));
  assert.deepStrictEqual(r, none);
});
caseEnd();

caseBegin("known-gap-proceed-prompt", "hooks/lib/user-dialog-turn.js");
test("known gap, intended: a proceed request answered with read-only tools then text is answering-user-prompt", () => {
  const r = kindOf(scene([U("Please proceed.", HUMAN), A(TU("Read")), R(), A(T("I read the plan."))]));
  assert.deepStrictEqual(r, answering);
});
caseEnd();

caseBegin("undecidable-is-not-dialog", "hooks/lib/user-dialog-turn.js");
test("flush undecidable (last_assistant_message never appears) -> decidable false, isUserDialogTurn false", () => {
  const input = scene([U("Where is it called from?"), A(T("From hooks/a.js."))], "A final text that is never flushed.");
  assert.strictEqual(kindOf(input).decidable, false);
  assert.strictEqual(mod().isUserDialogTurn(input), false);
});
test("missing transcript -> decidable false, isUserDialogTurn false", () => {
  const input = { session_id: "udt", transcript_path: path.join(ROOT, "absent.jsonl"), last_assistant_message: "x" };
  assert.strictEqual(kindOf(input).decidable, false);
  assert.strictEqual(mod().isUserDialogTurn(input), false);
});
test("corrupt transcript (no parseable line) -> isUserDialogTurn false", () => {
  assert.strictEqual(mod().isUserDialogTurn(scene(["{broken json", "also not json"], "")), false);
});
test("isUserDialogTurn never throws on a malformed input", () => {
  for (const bad of [undefined, null, 42, {}, { transcript_path: 7 }]) {
    assert.doesNotThrow(() => assert.strictEqual(mod().isUserDialogTurn(bad), false), `input ${JSON.stringify(bad)}`);
  }
});
caseEnd();

caseBegin("count-human-prompts-since", "hooks/lib/user-dialog-turn.js");
const T0 = "2026-10-01T00:00:00.000Z";
const at = (min) => new Date(Date.parse(T0) + min * 60000).toISOString();
const P = (text, min, extra = {}) => U(text, { timestamp: at(min), ...extra });
const count = (input, iso) => mod().countHumanPromptsSince(input, iso);
test("0 / 1 / 2 human prompts after iso", () => {
  const base = [P("first", 0), A(T("ok"))];
  assert.strictEqual(count(scene(base), at(1)), 0);
  assert.strictEqual(count(scene([...base, P("second", 2), A(T("ok2"))]), at(1)), 1);
  assert.strictEqual(count(scene([...base, P("second", 2), A(T("ok2")), P("third", 3), A(T("ok3"))]), at(1)), 2);
});
test("tool_result-only user lines, isMeta and isCompactSummary are not counted", () => {
  const entries = [P("first", 0), A(TU("Read")), { ...R(), timestamp: at(2) },
    P("meta injection", 3, { isMeta: true }), P("summary", 4, { isCompactSummary: true }), A(T("done"))];
  assert.strictEqual(count(scene(entries), at(1)), 0);
});
test("a task-notification user line is not counted", () => {
  const entries = [P("first", 0, HUMAN), A(T("ok")), P("<task-notification>run done</task-notification>", 2, NOTIFY), A(T("noted")),
    P("second", 3, HUMAN), A(T("ok2"))];
  assert.strictEqual(count(scene(entries), at(1)), 1);
});
test("a human prompt without a timestamp in range -> null", () => {
  const entries = [P("first", 0), A(T("ok")), U("no timestamp"), A(T("ok2"))];
  assert.strictEqual(count(scene(entries), at(1)), null);
});
test("an unparseable iso -> null; a missing transcript -> null", () => {
  assert.strictEqual(count(scene([P("first", 0), A(T("ok"))]), "not-a-date"), null);
  assert.strictEqual(count({ transcript_path: path.join(ROOT, "absent.jsonl") }, at(1)), null);
});
test("boundary: a prompt stamped exactly at iso is not counted (strictly after)", () => {
  const entries = [P("first", 0), A(T("ok")), P("at iso", 1), A(T("ok2"))];
  assert.strictEqual(count(scene(entries), at(1)), 0);
  assert.strictEqual(count(scene([...entries, P("after", 2), A(T("ok3"))]), at(1)), 1);
});
test("an unstamped prompt BEFORE the range does not make the count undecidable", () => {
  const entries = [U("old, unstamped"), A(T("ok0")), P("first", 0), A(T("ok")), P("second", 2), A(T("ok2"))];
  assert.strictEqual(count(scene(entries), at(1)), 1);
});
caseEnd();
