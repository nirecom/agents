"use strict";
// tests/hooks/feat-pm-leading-wrapper.js
// Tests: hooks/lib/leading-wrapper.js, hooks/lib/typed-slash-command.js, hooks/lib/supervisor-codex-input/rules.js, hooks/lib/step-in-flight-policy.js
// Tags: TL1, scope:common, issue-2942, pm-session, user-prompt-submit, prompt, slash-command
// #2942 S1: stripLeadingWrappers(prompt) -> {ok:true,text} | {ok:false,reason} removes the IDE / system
// wrappers and unwraps <pasted_content ...> at the prompt start; classifyTypedSlashCommand(prompt, names)
// -> {status: hit|none|undecidable, name, args, reason}; stripLeadingTags and wfInitPromptArgs share it.
// The pasted case runs on a recorded live prompt (tests/lib/fixtures/pasted-content-recorded.json).
// TL3 gap (what this test does NOT catch):
// - a live UserPromptSubmit payload from a running Claude Code session, and its text-block joiner (both pinned);
// - a wrapper tag a newer Claude Code version adds in front of a typed slash command.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test, after } = require("node:test");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
after(() => restore());

const NAMES = ["pm-init", "pm-add", "pm-remove", "resume-session", "wf-init", "workflow-init"];
const fnOf = (rel, name) => {
  const fn = P.load(rel)[name];
  assert.strictEqual(typeof fn, "function", `${rel} does not export ${name} as a function`);
  return fn;
};
const strip = (p) => fnOf("hooks/lib/leading-wrapper.js", "stripLeadingWrappers")(p);
const classify = (p, names = NAMES) => fnOf("hooks/lib/typed-slash-command.js", "classifyTypedSlashCommand")(p, names);
const typed = (p, names = NAMES) => fnOf("hooks/lib/typed-slash-command.js", "typedSlashCommand")(p, names);
const stripTags = (p) => fnOf("hooks/lib/supervisor-codex-input/rules.js", "stripLeadingTags")(p);
const wfArgs = (p) => fnOf("hooks/lib/step-in-flight-policy.js", "wfInitPromptArgs")(p);

const REC = JSON.parse(fs.readFileSync(path.join(P.ROOT, "tests", "lib", "fixtures", "pasted-content-recorded.json"), "utf8"));
// The hook receives the text blocks as one prompt; the joiner is not recorded, so both are pinned.
const RECORDED = [["recorded pasted prompt (blocks joined by \"\")", REC.blocks.join("")], ["recorded pasted prompt (blocks joined by \"\\n\")", REC.blocks.join("\n")]];

const IDE = "<ide_opened_file>The user opened the file c:\\x\\a.md in the IDE.</ide_opened_file>";
const SEL = "<ide_selection>The user selected lines 1 to 3 of a.md: foo</ide_selection>";
const SYS = "<system-reminder>\nnote\n</system-reminder>";
const pasted = (body, id = "1a2b") => `<pasted_content id="${id}">\n${body}\n</pasted_content id="${id}">`;

// [label, prompt, expected text (compared trimmed)]
const STRIP_OK = [
  ["ide_opened_file is stripped", `${IDE}\n/pm-init PM-a #1`, "/pm-init PM-a #1"],
  ["ide_selection is stripped", `${SEL}\n/pm-add #2`, "/pm-add #2"],
  ["system-reminder is stripped", `${SYS}\n/pm-remove #3`, "/pm-remove #3"],
  ["pasted_content with an id attribute is unwrapped", pasted("/pm-add #5"), "/pm-add #5"],
  ["plain <pasted_content> is unwrapped", "<pasted_content>\n/pm-add #6\n</pasted_content>", "/pm-add #6"],
  ["several leading wrappers in order", `${IDE}\n${SYS}\n\n${pasted("/pm-init PM-b #7\nnote")}`, "/pm-init PM-b #7\nnote"],
  ["no wrapper passes through", "hello world", "hello world"],
  ["empty prompt", "", ""],
  ["a wrapper not at the start is left in place", `hi ${IDE}`, `hi ${IDE}`],
  ["the <command-message> wrapped form is not a leading wrapper", P.wrapped("pm-init", "PM-a"), P.wrapped("pm-init", "PM-a")],
];
const STRIP_FAIL = [
  ["unclosed ide_opened_file", "<ide_opened_file>opened a.md\n/pm-init PM-a"],
  ["unclosed pasted_content", "<pasted_content id=\"9z\">\n/pm-add #5\n"],
  ["unknown leading tag kind", "<foo_bar>x</foo_bar>\n/pm-init PM-a"],
  ["pasted_content close id differs from the open id", "<pasted_content id=\"aa\">\n/pm-add #5\n</pasted_content id=\"bb\">"],
  ["known wrapper followed by an unclosed one", `${IDE}\n<system-reminder>never closed /pm-init`],
];

caseBegin("leading-wrapper-strip-ok", "hooks/lib/leading-wrapper.js");
for (const [label, prompt, want] of STRIP_OK) {
  test(`${label} -> ok`, () => {
    const r = strip(prompt);
    assert.strictEqual(r.ok, true, JSON.stringify(r));
    assert.strictEqual(String(r.text).trim(), want.trim());
  });
}
for (const [label, prompt] of RECORDED) {
  test(`${label}: unwrapped text starts with the typed command`, () => {
    const r = strip(prompt);
    assert.strictEqual(r.ok, true, JSON.stringify(r));
    assert.ok(String(r.text).trim().startsWith("/pm-init PM-infra #2728"), JSON.stringify(r.text));
  });
}
test("stripping is idempotent on its own output", () => {
  const once = strip(`${IDE}\n${pasted("/pm-add #5")}`);
  const twice = strip(once.text);
  assert.strictEqual(twice.ok, true);
  assert.strictEqual(String(twice.text).trim(), String(once.text).trim());
});
caseEnd();

caseBegin("leading-wrapper-strip-fail", "hooks/lib/leading-wrapper.js");
for (const [label, prompt] of STRIP_FAIL) {
  test(`${label} -> ok:false with a reason`, () => {
    const r = strip(prompt);
    assert.strictEqual(r.ok, false, JSON.stringify(r));
    assert.ok(typeof r.reason === "string" && r.reason.length > 0, JSON.stringify(r));
  });
}
test("a cross-session message is never unwrapped", () => {
  const r = strip(P.crossSession("/pm-init PM-evil #1"));
  if (r.ok) assert.ok(String(r.text).trimStart().startsWith("<cross-session-message"), JSON.stringify(r.text));
});
caseEnd();

// [label, prompt, status, {name,args} for a hit]
const CLASSIFY = [
  ["wrapped /pm-init", P.wrapped("pm-init", "PM-a #1"), "hit", { name: "pm-init", args: "PM-a #1" }],
  ["bare /pm-add", "/pm-add #5 reason", "hit", { name: "pm-add", args: "#5 reason" }],
  ["/pm-init after ide_opened_file", `${IDE}\n/pm-init PM-a #1`, "hit", { name: "pm-init", args: "PM-a #1" }],
  ["/pm-remove inside pasted_content", pasted("/pm-remove #3"), "hit", { name: "pm-remove", args: "#3" }],
  ["wrapped /wf-init after system-reminder", `${SYS}\n${P.wrapped("wf-init", "#9")}`, "hit", { name: "wf-init", args: "#9" }],
  ...RECORDED.map(([l, p]) => [l, p, "hit", REC.expect]),
  ["plain prose", "please look at #5", "none"],
  ["empty prompt", "", "none"],
  ["non-target command", "/commit-push #12", "none"],
  ["non-target command inside pasted_content", pasted("/commit-push #12"), "none"],
  ["cross-session message carrying /pm-init", P.crossSession(P.wrapped("pm-init", "PM-evil #1")), "none"],
  ["the recorded cross-session message", P.recordedCrossSession(), "none"],
  ["unclosed wrapper before /pm-init", "<ide_opened_file>opened\n/pm-init PM-a", "undecidable"],
  ["unknown tag before /pm-add", "<foo_bar>x</foo_bar>\n/pm-add #5", "undecidable"],
  ["unclosed pasted_content carrying /pm-init", "<pasted_content id=\"9z\">\n/pm-init PM-a\n", "undecidable"],
];

caseBegin("classify-typed-slash-command-verdicts", "hooks/lib/typed-slash-command.js");
for (const [label, prompt, status, want] of CLASSIFY) {
  test(`${label} -> ${status}`, () => {
    const r = classify(prompt);
    assert.strictEqual(r.status, status, JSON.stringify(r));
    if (status === "hit") assert.deepStrictEqual({ name: r.name, args: String(r.args).trim() }, want);
    if (status === "undecidable") assert.ok(typeof r.reason === "string" && r.reason.length > 0, JSON.stringify(r));
  });
}
test("a name outside the list is none, not hit", () => assert.strictEqual(classify(pasted("/pm-init PM-a"), ["wf-init"]).status, "none"));
caseEnd();

caseBegin("typed-slash-command-thin-wrapper", "hooks/lib/typed-slash-command.js");
for (const [label, prompt, status] of CLASSIFY) {
  test(`typedSlashCommand agrees with classify: ${label}`, () => {
    const c = classify(prompt);
    const t = typed(prompt);
    if (status === "hit") assert.deepStrictEqual({ name: t.name, args: String(t.args).trim() }, { name: c.name, args: String(c.args).trim() });
    else assert.strictEqual(t, null, JSON.stringify(t));
  });
}
caseEnd();

caseBegin("strip-leading-tags-delegates", "hooks/lib/supervisor-codex-input/rules.js");
for (const [label, prompt] of [...STRIP_OK, ...RECORDED]) {
  test(`stripLeadingTags matches stripLeadingWrappers: ${label}`, () => {
    const w = strip(prompt);
    assert.strictEqual(w.ok, true, JSON.stringify(w));
    assert.strictEqual(String(stripTags(prompt)).trim(), String(w.text).trim());
  });
}
test("rules.js drops its own LEADING_TAG_RE and delegates to leading-wrapper", () => {
  const src = fs.readFileSync(path.join(P.ROOT, "hooks", "lib", "supervisor-codex-input", "rules.js"), "utf8");
  assert.ok(!src.includes("LEADING_TAG_RE"), "rules.js still defines LEADING_TAG_RE");
  assert.ok(src.includes("leading-wrapper"), "rules.js does not reference hooks/lib/leading-wrapper.js");
});
caseEnd();

caseBegin("wf-init-prompt-args-through-wrappers", "hooks/lib/step-in-flight-policy.js");
for (const [label, prompt, want] of [
  ["/wf-init inside pasted_content", pasted("/wf-init #7"), "#7"],
  ["wrapped /workflow-init after ide_opened_file", `${IDE}\n${P.wrapped("workflow-init", "#8 #9")}`, "#8 #9"],
  ["unclosed wrapper before /wf-init (undecidable)", "<ide_opened_file>x\n/wf-init #7", null],
  ["unknown tag before /wf-init (undecidable)", "<foo_bar>x</foo_bar>\n/wf-init #7", null],
]) {
  test(`${label} -> ${JSON.stringify(want)}`, () => {
    const got = wfArgs(prompt);
    assert.strictEqual(typeof got === "string" ? got.trim() : got, want);
  });
}
caseEnd();
