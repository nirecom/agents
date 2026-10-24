"use strict";
// Tests: hooks/lib/permission-decision-output.js
// Tags: TL1, hooks, pretooluse, permission-decision, allow-deny-hook, output-shape, scope:issue-specific
// #2676: the one place that builds a PreToolUse permission-decision output. Gate 1 (b) settled the
// branch as b-rejected: the legacy {decision:"approve"} still allows, so approve keeps that shape.
// none() never carries a decision key, so "no decision" can never turn into an approve.
// TL3 gap (what this test does NOT catch):
// - how a live Claude Code release reads each shape (approve / {} / allow / silence)
// Closest-to-action mitigation: tests/hooks/TL3-hook-bash-guard-envelope.sh section (b).
const { isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.resolve(__dirname, "..", "..");
const MOD = path.join(REPO, "hooks", "lib", "permission-decision-output.js");
const restore = isolate();
after(() => restore());

let loaded = null;
let loadError = null;
try { loaded = require(MOD); } catch (err) { loadError = err; }
const mod = () => {
  assert.ok(loaded, `hooks/lib/permission-decision-output.js loads (${loadError && loadError.message})`);
  return loaded;
};

// A builder may return the object or its JSON text; both are read as the object.
const shape = (value) => (typeof value === "string" ? JSON.parse(value) : value);
// additionalContext may sit at the top level or under hookSpecificOutput (bash-guard's notify
// puts it there today); either placement keeps it.
const contextOf = (out) => out.additionalContext
  ?? (out.hookSpecificOutput ? out.hookSpecificOutput.additionalContext : undefined);
const REASON = "example reason";
const EXTRAS = { systemMessage: "note for the user", additionalContext: "note for the session" };

test("exports the five builders", () => {
  for (const name of ["deny", "ask", "allow", "approve", "none"]) {
    assert.strictEqual(typeof mod()[name], "function", `${name} is exported as a function`);
  }
});

test("deny carries both the legacy block and permissionDecision deny", () => {
  const out = shape(mod().deny(REASON));
  assert.strictEqual(out.decision, "block");
  assert.strictEqual(out.reason, REASON);
  assert.deepStrictEqual(out.hookSpecificOutput, {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: REASON,
  });
});

test("ask is permissionDecision ask with the reason and no legacy decision", () => {
  const out = shape(mod().ask(REASON));
  assert.strictEqual(out.hookSpecificOutput.hookEventName, "PreToolUse");
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
  assert.strictEqual(out.hookSpecificOutput.permissionDecisionReason, REASON);
  assert.ok(!("decision" in out), "ask has no legacy decision key");
});

test("allow is permissionDecision allow with the reason", () => {
  const out = shape(mod().allow(REASON));
  assert.strictEqual(out.hookSpecificOutput.hookEventName, "PreToolUse");
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "allow");
  assert.strictEqual(out.hookSpecificOutput.permissionDecisionReason, REASON);
  assert.ok(!("decision" in out), "allow has no legacy decision key");
});

test("approve keeps the legacy shape on the b-rejected branch", () => {
  assert.deepStrictEqual(shape(mod().approve()), { decision: "approve" });
});

test("approve keeps systemMessage and additionalContext", () => {
  const out = shape(mod().approve(EXTRAS));
  assert.strictEqual(out.decision, "approve");
  assert.strictEqual(out.systemMessage, EXTRAS.systemMessage);
  assert.strictEqual(contextOf(out), EXTRAS.additionalContext);
});

test("none is the empty object", () => {
  assert.deepStrictEqual(shape(mod().none()), {});
  assert.deepStrictEqual(shape(mod().none({})), {});
});

test("none never carries a decision or permissionDecision key, even with extras", () => {
  const out = shape(mod().none(EXTRAS));
  assert.ok(!("decision" in out), "none has no decision key");
  assert.ok(!("hookSpecificOutput" in out) || !("permissionDecision" in out.hookSpecificOutput),
    "none has no permissionDecision key");
  assert.strictEqual(out.systemMessage, EXTRAS.systemMessage);
  assert.strictEqual(contextOf(out), EXTRAS.additionalContext);
});

test("none differs from approve, so no decision is never read as an approve", () => {
  assert.notDeepStrictEqual(shape(mod().none()), shape(mod().approve()));
});
