"use strict";
// SSOT for the delegated-step in-flight policy (#2013).
// Rationale + membership decisions: docs/architecture/claude-code/workflow.md
// (section "Delegated-step in-flight allow-list").
//
// DEPENDENCY-FREE ON PURPOSE: required from the hooks tree and from
// hooks/workflow-state/lifecycle.js alike, so any require() would close a cycle.

// Steps whose work is genuinely delegated to a subagent. write_code is excluded
// deliberately — it keeps its own isWriteCodeInFlight predicate.
const STEP_IN_FLIGHT_ALLOWLIST = Object.freeze([
  "research",
  "detail",
  "write_tests",
  "review_tests",
]);

// How long an `in_progress` record on an allowlisted step may keep the Stop
// guard quiet. Wall-clock elapsed against `updated_at`; never `updated_seq`.
const STEP_IN_FLIGHT_TTL_MS = 4 * 60 * 60 * 1000;

// Tools whose PostToolUse event means "a delegated unit of work just ran".
const DISPATCH_TOOLS = Object.freeze(["Agent", "Task", "Skill"]);

function isStepInFlightCandidate(step) {
  return typeof step === "string" && STEP_IN_FLIGHT_ALLOWLIST.indexOf(step) !== -1;
}

function isDispatchTool(toolName) {
  return typeof toolName === "string" && DISPATCH_TOOLS.indexOf(toolName) !== -1;
}

// The shared freshness rule, applied to a projected step entry. Fail-CLOSED —
// a record that cannot prove its age is not fresh.
function isFreshInFlightEntry(entry, ttlMs) {
  const ttl = typeof ttlMs === "number" && ttlMs > 0 ? ttlMs : STEP_IN_FLIGHT_TTL_MS;
  if (!entry || typeof entry !== "object") return false;
  if (entry.status !== "in_progress") return false;
  if (typeof entry.updated_at !== "string") return false;
  const updatedAt = Date.parse(entry.updated_at);
  if (Number.isNaN(updatedAt)) return false;
  return Date.now() - updatedAt < ttl;
}

module.exports = {
  STEP_IN_FLIGHT_ALLOWLIST,
  STEP_IN_FLIGHT_TTL_MS,
  DISPATCH_TOOLS,
  isStepInFlightCandidate,
  isDispatchTool,
  isFreshInFlightEntry,
};
