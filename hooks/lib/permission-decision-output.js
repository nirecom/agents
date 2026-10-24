"use strict";
// hooks/lib/permission-decision-output.js — the one builder of a PreToolUse permission-decision
// output (#2676). Gate 1 (b) kept the legacy {decision:"approve"} as a working allow, so approve
// keeps that shape; none() never carries a decision, so "no decision" never reads as approve.

const EVENT = "PreToolUse";

// extras: { systemMessage?, additionalContext? } — blank values are dropped.
function withExtras(base, extras, specific) {
  const out = { ...base };
  const message = extras && typeof extras.systemMessage === "string" && extras.systemMessage !== "" ? extras.systemMessage : null;
  const context = extras && typeof extras.additionalContext === "string" && extras.additionalContext !== "" ? extras.additionalContext : null;
  if (message !== null) out.systemMessage = message;
  const hookSpecificOutput = specific ? { ...specific } : null;
  if (context !== null) {
    if (hookSpecificOutput) hookSpecificOutput.additionalContext = context;
    else out.hookSpecificOutput = { hookEventName: EVENT, additionalContext: context };
  }
  if (hookSpecificOutput) out.hookSpecificOutput = hookSpecificOutput;
  return out;
}

const permission = (permissionDecision, reason) =>
  ({ hookEventName: EVENT, permissionDecision, permissionDecisionReason: String(reason == null ? "" : reason) });

function deny(reason) {
  const text = String(reason == null ? "" : reason);
  return { decision: "block", reason: text, hookSpecificOutput: permission("deny", text) };
}

const ask = (reason, extras) => withExtras({}, extras, permission("ask", reason));
const allow = (reason, extras) => withExtras({}, extras, permission("allow", reason));
const approve = (extras) => withExtras({ decision: "approve" }, extras, null);
const none = (extras) => withExtras({}, extras, null);

module.exports = { deny, ask, allow, approve, none };
