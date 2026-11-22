"use strict";
// tests/hooks/feat-wf-init-prompt-args.js
// Tests: hooks/lib/step-in-flight-policy.js
// Tags: TL1, scope:common, wf-init, user-prompt-submit, prompt, pm-session
// #299: wfInitPromptArgs(prompt) returns the arguments of a typed /wf-init or /workflow-init
// (wrapped <command-args> content, or the rest of a bare first line), null for anything else.
// It reuses WF_INIT_WRAPPED_RE / WF_INIT_BARE_RE, so it agrees with promptInvokesWfInit.

// TL3 gap: the real VS Code / Claude app title rendering is not observed, and neither is the exact
// prompt text a live client delivers to UserPromptSubmit (the wrapped fixture follows fix-1633).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const path = require("node:path");

const restore = isolate();
after(() => restore());
const ROOT = path.resolve(__dirname, "..", "..");
const MOD = path.join(ROOT, "hooks", "lib", "step-in-flight-policy.js");

const wrapped = (name, args) => `<command-message>${name}</command-message>\n<command-name>/${name}</command-name>\n<command-args>${args}</command-args>`;

// [label, prompt, expected]
const TABLE = [
  ["wrapped /wf-init with args", wrapped("wf-init", "#12"), "#12"],
  ["wrapped /workflow-init with two refs", wrapped("workflow-init", "#12 #34"), "#12 #34"],
  ["wrapped /wf-init empty args", wrapped("wf-init", ""), ""],
  ["bare /wf-init #12", "/wf-init #12", "#12"],
  ["bare /workflow-init #12 other#5", "/workflow-init #12 other#5\nmore text", "#12 other#5"],
  ["bare namespaced /agents:workflow-init #7", "/agents:workflow-init #7", "#7"],
  ["bare /wf-init with nothing after", "/wf-init", ""],
  ["not wf-init", "/commit-push #12", null],
  ["prefix lookalike /wf-initx", "/wf-initx #12", null],
  ["/wf-init on line 2", "please\n/wf-init #12", null],
  ["plain text", "fix #12 please", null],
];

const norm = (v) => (typeof v === "string" ? v.trim() : v);
function wfInitPromptArgs() {
  const fn = require(MOD).wfInitPromptArgs;
  assert.strictEqual(typeof fn, "function", "wfInitPromptArgs is not exported as a function");
  return fn;
}

caseBegin("wf-init-prompt-args-table", "hooks/lib/step-in-flight-policy.js");
test("wfInitPromptArgs is exported as a function", () => wfInitPromptArgs());
for (const [label, prompt, want] of TABLE) {
  test(`${label} -> ${JSON.stringify(want)}`, () => assert.strictEqual(norm(wfInitPromptArgs()(prompt)), want));
  test(`${label} agrees with promptInvokesWfInit`, () => {
    const got = wfInitPromptArgs()(prompt);
    assert.strictEqual(got !== null, require(MOD).promptInvokesWfInit(prompt), JSON.stringify(got));
  });
}
caseEnd();

caseBegin("wf-init-prompt-args-non-string-is-null", "hooks/lib/step-in-flight-policy.js");
for (const bad of [null, undefined, 42]) {
  test(`non-string ${String(bad)} -> null`, () => assert.strictEqual(wfInitPromptArgs()(bad), null));
}
caseEnd();

// #2941: the wrapped form is anchored at the prompt start, and a cross-session message never
// counts as a typed /wf-init (it delegates to hooks/lib/typed-slash-command.js).
const P = require("../lib/pm-state-fixture");
const NOT_TYPED = [
  ["wrapped /wf-init after leading prose", `look:\n${wrapped("wf-init", "#12")}`],
  ["cross-session message carrying wrapped /wf-init", P.crossSession(wrapped("wf-init", "#12"))],
  ["cross-session message carrying bare /workflow-init", P.crossSession("/workflow-init #12")],
];
caseBegin("wf-init-prompt-args-anchored-2941", "hooks/lib/step-in-flight-policy.js");
for (const [label, prompt] of NOT_TYPED) {
  test(`${label} -> args null`, () => assert.strictEqual(wfInitPromptArgs()(prompt), null));
  test(`${label} -> promptInvokesWfInit false`, () => assert.strictEqual(require(MOD).promptInvokesWfInit(prompt), false));
}
caseEnd();

// #2942 S1: arguments are read through leading IDE / system / pasted wrappers; an undecidable prompt
// (unclosed or unknown leading wrapper) yields null.
const IDE = "<ide_opened_file>The user opened the file c:\\x\\a.md in the IDE.</ide_opened_file>";
caseBegin("wf-init-prompt-args-wrapped-2942", "hooks/lib/step-in-flight-policy.js");
for (const [label, prompt, want] of [
  ["bare /wf-init after ide_opened_file", `${IDE}\n/wf-init #12`, "#12"],
  ["wrapped /workflow-init after system-reminder", `<system-reminder>\nx\n</system-reminder>\n${wrapped("workflow-init", "#3 #4")}`, "#3 #4"],
  ["/wf-init inside pasted_content", "<pasted_content id=\"7f\">\n/wf-init #5\n</pasted_content id=\"7f\">", "#5"],
  ["unclosed leading wrapper", "<ide_opened_file>x\n/wf-init #12", null],
  ["unknown leading tag", "<foo_bar>x</foo_bar>\n/wf-init #12", null],
]) {
  test(`${label} -> ${JSON.stringify(want)}`, () => assert.strictEqual(norm(wfInitPromptArgs()(prompt)), want));
}
caseEnd();
