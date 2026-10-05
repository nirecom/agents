#!/usr/bin/env node
"use strict";
// hooks/jev-shadow-post.js — PostToolUse (Agent|Task): pairs the complexity-judge LLM
// answer with the pre hook's Jev result by tool_use_id (#2460) and writes one decision
// record. Shadow mode: the LLM answer is always the one adopted and nothing is written to
// stdout, so the parent conversation never sees Jev. Fail-open, always exits 0.

// Snapshot the JEV_* test overrides before anything can load .env into process.env.
const { captureTestOverrides } = require("./lib/jev/test-overrides");
const OVERRIDES = captureTestOverrides(process.env);

const { readStdinJson, matchDispatch } = require("./lib/jev/dispatch-gate");

function main() {
  // The LLM's end, taken before stdin parsing and housekeeping can inflate its latency.
  const endTs = Date.now();
  const payload = readStdinJson("jev-shadow-post", "decision record not written");
  if (!payload) return null;
  const toolInput = payload.tool_input && typeof payload.tool_input === "object" ? payload.tool_input : {};
  const gate = matchDispatch({
    toolName: payload.tool_name,
    subagentType: toolInput.subagent_type,
    agentId: payload.agent_id,
    sessionId: payload.session_id,
    toolUseId: payload.tool_use_id,
  });
  if (!gate) return null;
  // Heavy requires only after the cheap gate passed.
  const broker = require("./lib/jev/broker");
  if (!broker.isEnabled()) return null;
  const { registryEntry } = require("./lib/jev/registry");
  const adapter = require(registryEntry(gate.point).adapter);
  const cwd = typeof payload.cwd === "string" ? payload.cwd : undefined;

  // Record first: an unbounded sweep must not eat the hook timeout before the record lands.
  const result = broker.recordShadow({
    point: gate.point,
    sessionId: gate.sessionId,
    toolUseId: gate.toolUseId,
    llmText: adapter.extractLlmText(payload.tool_response, payload),
    toolInput,
    step: broker.resolveStep(gate.point, gate.sessionId, cwd),
    endTs,
  });

  try { broker.sweepSession(gate.sessionId, OVERRIDES, { skipTid: gate.toolUseId }); } catch (_e) { /* best effort */ }
  try { broker.runRetention(); } catch (_e) { /* best effort */ }

  return result;
}

if (require.main === module) {
  try {
    main();
  } catch (_e) { /* fail-open */ }
  process.exit(0);
}

module.exports = { main };
