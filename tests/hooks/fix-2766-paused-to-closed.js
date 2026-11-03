"use strict";
// Tests: hooks/lib/supervisor-state-writer/shared.js
// Tags: fix-2766, supervisor, alert-phase, paused, closed, session-close, scope:issue-specific, TL1, pwsh-not-required
// #2766: validateAlertPhaseTransition let paused move only to pending, so session close could not
// settle a paused alert as closed. paused->closed is now allowed; every other exit from a terminal
// phase stays rejected. The close-alert-phase.sh side lives in tests/skills/fix-2766-close-alert-phase.sh.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, test } = require("node:test");

const restoreIsolation = isolate();
after(() => restoreIsolation());

const ROOT = path.resolve(__dirname, "..", "..");
const { validateAlertPhaseTransition } = require(path.join(ROOT, "hooks", "lib", "supervisor-state-writer", "shared.js"));
const W = require(path.join(ROOT, "hooks", "lib", "supervisor-state-writer"));

caseBegin("transition-paused-to-closed-is-allowed", "hooks/lib/supervisor-state-writer/shared.js");
test("transition-paused-to-closed-is-allowed", () => {
  const v = validateAlertPhaseTransition("paused", "closed");
  assert.strictEqual(v.ok, true, JSON.stringify(v));
  assert.deepStrictEqual(v.errors, []);
});
caseEnd();

caseBegin("writer-closes-a-paused-alert", "hooks/lib/supervisor-state-writer/shared.js");
test("writer-closes-a-paused-alert", () => {
  const sid = "f2766-writer-1";
  assert.strictEqual(W.writeAlertState(sid, { alert_phase: "paused" }), true, "fixture: seed paused");
  assert.strictEqual(W.writeAlertState(sid, { alert_phase: "closed" }), true, "paused->closed must be written");
  assert.strictEqual(W.readState(sid).alert.alert_phase, "closed");
});
caseEnd();

caseBegin("other-terminal-transitions-stay-rejected", "hooks/lib/supervisor-state-writer/shared.js");
test("other-terminal-transitions-stay-rejected", () => {
  for (const [from, to] of [["paused", "done"], ["closed", "pending"], ["closed", "paused"], ["done", "pending"]]) {
    const v = validateAlertPhaseTransition(from, to);
    assert.strictEqual(v.ok, false, `${from}->${to} must stay rejected: ${JSON.stringify(v)}`);
    assert.ok(v.errors.length > 0);
  }
  assert.strictEqual(validateAlertPhaseTransition("paused", "pending").ok, true, "paused->pending re-arm stays allowed");
});
caseEnd();
