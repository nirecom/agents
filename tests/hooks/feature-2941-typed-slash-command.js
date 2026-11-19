"use strict";
// tests/hooks/feature-2941-typed-slash-command.js
// Tests: hooks/lib/typed-slash-command.js
// Tags: TL1, scope:issue-specific, pm-session, user-prompt-submit, prompt, slash-command
// #2941 typedSlashCommand(prompt, names): wrapped and bare forms anchored at the prompt start,
// <cross-session-message never counts, `ns:` accepted (spec: detail plan Files table / Steps 1).
// The cross-session cases run on a recorded live payload (tests/lib/fixtures/cross-session-message-recorded.json)
// with only its body swapped. TL3 gap: a future client that changes the wrapper is caught only by re-recording.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
after(() => restore());

// Assumed result: name is the bare command name (no slash, no `ns:`); args are compared trimmed.
const NAMES = ["pm-init", "pm-add", "pm-remove", "resume-session", "wf-init", "workflow-init"];
function typed() {
  const fn = P.load("hooks/lib/typed-slash-command.js").typedSlashCommand;
  assert.strictEqual(typeof fn, "function", "typedSlashCommand is not exported as a function");
  return fn;
}
const norm = (r) => (r === null || r === undefined ? null : { name: r.name, args: String(r.args === undefined ? "" : r.args).trim() });

// [label, prompt, expected]
const HIT = [
  ["wrapped /pm-init with tag and refs", P.wrapped("pm-init", "PM-infra #2728 #2927"), { name: "pm-init", args: "PM-infra #2728 #2927" }],
  ["wrapped /pm-add", P.wrapped("pm-add", "#5 reason"), { name: "pm-add", args: "#5 reason" }],
  ["wrapped /resume-session --from", P.wrapped("resume-session", "--from 0000abcd-0000-4000-8000-000000000001"), { name: "resume-session", args: "--from 0000abcd-0000-4000-8000-000000000001" }],
  ["wrapped empty args", P.wrapped("pm-remove", ""), { name: "pm-remove", args: "" }],
  ["bare /pm-init", "/pm-init PM-infra theme", { name: "pm-init", args: "PM-infra theme" }],
  ["bare /pm-remove with later lines", "/pm-remove #5\nmore text", { name: "pm-remove", args: "#5" }],
  ["bare /wf-init with nothing after", "/wf-init", { name: "wf-init", args: "" }],
  ["bare namespaced /agents:pm-init", "/agents:pm-init PM-x #7", { name: "pm-init", args: "PM-x #7" }],
  ["wrapped namespaced agents:workflow-init", P.wrapped("agents:workflow-init", "#7"), { name: "workflow-init", args: "#7" }],
];

const MISS = [
  ["non-target command", "/commit-push #12"],
  ["prefix lookalike /pm-initx", "/pm-initx PM-a"],
  ["bare command on line 2", "please\n/pm-init PM-a"],
  ["wrapped command after leading prose", `see this:\n${P.wrapped("pm-init", "PM-a #1")}`],
  ["plain text naming the command", "can you run /pm-init PM-a later"],
  ["cross-session message carrying a wrapped /pm-init", P.crossSession(P.wrapped("pm-init", "PM-evil #1"))],
  ["cross-session message carrying a bare /pm-add", P.crossSession("/pm-add #1")],
  ["cross-session message carrying /wf-init", P.crossSession(P.wrapped("wf-init", "#1"))],
  ["the recorded cross-session message unchanged", P.recordedCrossSession()],
  ["empty string", ""],
];

caseBegin("typed-slash-command-hits", "hooks/lib/typed-slash-command.js");
test("typedSlashCommand is exported as a function", () => typed());
for (const [label, prompt, want] of HIT) {
  test(`${label} -> ${JSON.stringify(want)}`, () => assert.deepStrictEqual(norm(typed()(prompt, NAMES)), want));
}
caseEnd();

caseBegin("typed-slash-command-recorded-wrapper", "hooks/lib/typed-slash-command.js");
test("the recorded live payload starts with the <cross-session-message wrapper", () => {
  assert.match(P.recordedCrossSession(), /^<cross-session-message from="[^"]+" from-name="[^"]*" from-mode="[^"]*">\n\[peer-msg v1\] /);
});
caseEnd();

caseBegin("typed-slash-command-misses", "hooks/lib/typed-slash-command.js");
for (const [label, prompt] of MISS) {
  test(`${label} -> null`, () => assert.strictEqual(norm(typed()(prompt, NAMES)), null));
}
test("a name outside the given list is not a hit", () => assert.strictEqual(norm(typed()("/pm-init PM-a", ["wf-init"])), null));
for (const bad of [null, undefined, 42, {}]) {
  test(`non-string prompt ${String(bad)} -> null`, () => assert.strictEqual(norm(typed()(bad, NAMES)), null));
}
caseEnd();
