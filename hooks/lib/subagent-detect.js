"use strict";
// Predicate: is this PreToolUse/PostToolUse call from a subagent?
//
// Empirically confirmed: agent_id is populated in subagent PreToolUse payloads
// and absent in main conversation (docs/hook-block-tests-direct.md:72-77).
// Fail-safe: returns false when agent_id is absent (treats as main conversation)
// so PostToolUse backstop in workflow-mark.js falls back to normal processing
// when the data gap applies.

function isSubagentCall(input) {
  return !!(input && typeof input.agent_id === "string" && input.agent_id.length > 0);
}

module.exports = { isSubagentCall };
