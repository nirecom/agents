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

// Tools whose dispatch may ESCALATE a null/workflow_init step to the WI-10
// lookahead step. Narrower than DISPATCH_TOOLS on purpose (#2279 D-3): a Skill
// call is the user driving the workflow, not a subagent doing a step's work, so
// it never invents a step the session has not reached.
const LOOKAHEAD_DISPATCH_TOOLS = Object.freeze(["Agent", "Task"]);

// The only step the WI-10 lookahead can synthesize. Readers use it to tell that
// artifact apart from a real in-flight mark carrying the same origin.
const LOOKAHEAD_PREINIT_STEP = "research";

// Skills that OPERATE ON the workflow record instead of advancing it. A dispatch
// of one must leave the state untouched — /resume-session marking the heir busy
// is what disqualifies it from the adoption it was invoked to perform (#2279).
const META_OP_SKILLS = Object.freeze(["resume-session"]);

function isStepInFlightCandidate(step) {
  return typeof step === "string" && STEP_IN_FLIGHT_ALLOWLIST.indexOf(step) !== -1;
}

// Accepts either the raw `tool_input.skill` string or the whole tool_input
// object, because callers hold one or the other. Claude Code may deliver a skill
// as a bare name, a `<namespace>:<name>` pair or a path. Total function — an
// unresolvable payload yields null (see isMetaOpDispatch for the fail direction
// that choice serves).
function skillNameOf(skillOrToolInput) {
  let raw = skillOrToolInput;
  if (raw && typeof raw === "object" && !Array.isArray(raw)) raw = raw.skill;
  if (typeof raw !== "string" || !raw.length) return null;
  const last = raw.split("/").pop().split(":").pop().trim();
  return last.length ? last : null;
}

// Fail-OPEN: an unidentifiable skill name is NOT a meta-op, so the dispatch keeps
// whatever marking it would have had. The read-side discounting (#2279 lifecycle
// predicates) absorbs the misses this direction leaves behind.
function isMetaOpDispatch(toolName, skillOrToolInput) {
  if (toolName !== "Skill") return false;
  const name = skillNameOf(skillOrToolInput);
  if (!name) return false;
  const lowered = name.toLowerCase();
  return META_OP_SKILLS.some((s) => s.toLowerCase() === lowered);
}

function isLookaheadDispatchTool(toolName) {
  return typeof toolName === "string" && LOOKAHEAD_DISPATCH_TOOLS.indexOf(toolName) !== -1;
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
  LOOKAHEAD_DISPATCH_TOOLS,
  LOOKAHEAD_PREINIT_STEP,
  META_OP_SKILLS,
  isStepInFlightCandidate,
  isDispatchTool,
  isLookaheadDispatchTool,
  skillNameOf,
  isMetaOpDispatch,
  isFreshInFlightEntry,
};
