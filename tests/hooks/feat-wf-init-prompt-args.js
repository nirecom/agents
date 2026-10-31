"use strict";
// tests/hooks/feat-wf-init-prompt-args.js
// Tests: hooks/lib/step-in-flight-policy.js
// Tags: TL1, scope:common, wf-init, user-prompt-submit, prompt
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
