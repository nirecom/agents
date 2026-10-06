#!/usr/bin/env node
"use strict";
// hooks/jev-shadow-pre.js — PreToolUse (Agent|Task): Jev shadow query for a
// complexity-judge dispatch (#2460). Queries Jev before the LLM runs and leaves the
// result in pending state for jev-shadow-post.js. Never blocks or alters the dispatch:
// prints nothing, emits no permission decision, always exits 0.

// Snapshot the JEV_* test overrides before anything can load .env into process.env.
const { captureTestOverrides } = require("./lib/jev/test-overrides");
const OVERRIDES = captureTestOverrides(process.env);

const { readStdinJson, matchDispatch } = require("./lib/jev/dispatch-gate");

async function main() {
  const payload = readStdinJson("jev-shadow-pre", "shadow query skipped");
  if (!payload) return;
  const toolInput = payload.tool_input && typeof payload.tool_input === "object" ? payload.tool_input : {};
  const gate = matchDispatch({
    toolName: payload.tool_name,
    subagentType: toolInput.subagent_type,
    agentId: payload.agent_id,
    sessionId: payload.session_id,
    toolUseId: payload.tool_use_id,
  });
  if (!gate) return;
  // Heavy requires only after the cheap gate passed.
  const broker = require("./lib/jev/broker");
  if (!broker.isEnabled()) return;
  const cwd = typeof payload.cwd === "string" ? payload.cwd : undefined;
  await broker.queryShadow({
    point: gate.point,
    sessionId: gate.sessionId,
    toolUseId: gate.toolUseId,
    toolInput,
    step: broker.resolveStep(gate.point, gate.sessionId, cwd),
    cwd,
    overrides: OVERRIDES,
  });
}

// Exit by draining the event loop, not process.exit(): exiting while fetch's socket is
// still closing trips a libuv assertion on Windows (UV_HANDLE_CLOSING, exit 127).
// undici unrefs idle keep-alive sockets, so the loop drains once the work is done.
if (require.main === module) {
  process.exitCode = 0;
  main()
    .catch(() => { /* fail-open: the dispatch must never depend on Jev */ })
    .finally(() => { process.exitCode = 0; });
}

module.exports = { main };
