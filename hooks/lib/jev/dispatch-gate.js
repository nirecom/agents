"use strict";
// hooks/lib/jev/dispatch-gate.js — the cheap fast-exit gate shared by jev-shadow-pre/post.
// Every Agent/Task dispatch spawns both hooks, so this must decide "not ours" before any
// heavy require (load-env, broker): it reads only stdin (through the shared reader) and
// the data-only registry. The broker is loaded here only on the unreadable-stdin path.

const { readHookInput, readFailOpenDiagnostic } = require("../read-stdin");
const { REGISTRY } = require("./registry");
const { isValidId } = require("./state-paths");

const AGENT_TOOLS = new Set(["Agent", "Task"]);

// The hook payload, or null when stdin is unreadable, empty, or not a JSON object: the
// hook then exits 0 (fail-open). `effect` names what the caller skips in that case.
function readStdinJson(hookName, effect) {
  let result = readHookInput();
  if (result.kind === "ok") {
    const o = result.input;
    if (o && typeof o === "object" && !Array.isArray(o)) return o;
    result = { kind: "json-invalid", text: result.text, error: new TypeError("hook input is not an object") };
  }
  warnUnreadable(hookName, result, effect);
  return null;
}

// One stderr line, and only when JEV is on: with it off nothing was going to be queried
// or recorded, so there is no skipped record to report on every Agent/Task dispatch.
function warnUnreadable(hookName, result, effect) {
  try {
    if (!require("./broker").isEnabled()) return;
    const line = readFailOpenDiagnostic(hookName, result, effect);
    if (line) process.stderr.write(line + "\n");
  } catch (_e) { /* fail-open: the diagnostic is best effort */ }
}

// {point, sessionId, toolUseId} when this dispatch is a registered shadow point made by
// the main agent; null otherwise (other tool, other subagent, a subagent's own turn,
// or an id that fails the path-segment guard).
function matchDispatch({ toolName, subagentType, agentId, sessionId, toolUseId }) {
  if (!AGENT_TOOLS.has(toolName)) return null;
  if (agentId !== undefined && agentId !== null && agentId !== "") return null;
  const point = findPointBySubagentType(subagentType);
  if (!point) return null;
  if (!isValidId(sessionId) || !isValidId(toolUseId)) return null;
  return { point, sessionId, toolUseId };
}

function findPointBySubagentType(type) {
  if (typeof type !== "string") return null;
  for (const [point, entry] of Object.entries(REGISTRY)) {
    if (entry.subagent_type === type) return point;
  }
  return null;
}

module.exports = { readStdinJson, matchDispatch, findPointBySubagentType };
