"use strict";
// Tests: hooks/workflow-gate/early-gate-messages.js
// Tags: TL1, hooks, workflow-gate, early-gate, conv-lang, model-facing, scope:issue-specific
// #2731 S3: the early-gate block reason is model-facing, so both branches (main and subagent) and
// both tiers carry the CONV_LANG directive exactly once under japanese and none under english.
// TL3 gap (what this test does NOT catch):
// - the model answering in the injected language after the PreToolUse block
// Closest-to-action mitigation: the pure builder is the only place the reason text is assembled.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const { after, test } = require("node:test");
const C = require("../lib/system-message-contract");

const restore = isolate();
after(() => restore());

const { buildEarlyGateReason } = require("../../hooks/workflow-gate/early-gate-messages");
const withLang = (lang, fn) => {
  const prev = process.env.CONV_LANG;
  process.env.CONV_LANG = lang;
  try { return fn(); } finally {
    if (prev === undefined) delete process.env.CONV_LANG;
    else process.env.CONV_LANG = prev;
  }
};
const TARGETS = { plans: "/tmp/plans", scratchpad: "/tmp/scratch" };

caseBegin("early-gate-reason-conv-lang", "hooks/workflow-gate/early-gate-messages.js");
for (const tier of ["workflow_init", "clarify_intent"]) {
  for (const isSubagent of [false, true]) {
    const label = `${tier} ${isSubagent ? "subagent" : "main"}`;
    const marker = isSubagent ? "Subagent context:" : "To complete:";
    const build = () => buildEarlyGateReason({ tier, toolName: "Write", isSubagent, allowedTargets: TARGETS });
    test(`buildEarlyGateReason(${label}): japanese -> directive once at the head`, () => {
      const ja = withLang("japanese", build);
      assert.ok(C.prefixedOnce(ja, "japanese"), `directive once at the head:\n${ja}`);
      assert.ok(ja.includes(marker), `the ${label} branch body survives the prefix`);
      assert.ok(ja.includes("ALLOWED: /tmp/plans"), "the ALLOWED targets survive the prefix");
    });
    test(`buildEarlyGateReason(${label}): english -> unchanged, no directive`, () => {
      const en = withLang("english", build);
      assert.strictEqual(C.countDirective(en), 0, `no directive under english:\n${en}`);
      assert.ok(en.startsWith(`workflow-gate: ${tier} has not been completed`), "english starts with the original head");
      assert.ok(en.includes(marker), `the ${label} branch body`);
    });
  }
}
caseEnd();
