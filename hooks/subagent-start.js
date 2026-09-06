#!/usr/bin/env node
// Claude Code SubagentStart hook: inject conversation language directive into subagent context

const fs = require("fs");
const { getConvLangInjection } = require("./lib/conv-lang");
const { getPlanLangInjection } = require("./lib/lang-config");
const { codegraphEnabled } = require("./lib/codegraph-boundary");

// The same pointer the nine adopting agents/*.md carry, extended to every
// subagent — built-in Explore/general-purpose/Plan agents included.
const CODEGRAPH_POINTER =
  "Before a Read/Grep sweep of unfamiliar code, try `mcp__codegraph__codegraph_explore` first — usage and the projectPath caveat: agents/lib/codegraph-usage.md";

// Planner/reviewer agents that write plan artifacts. Only these receive the
// proactive PLAN_LANG directive; other subagents (workers) do not.
const PLAN_AGENTS = new Set([
  "outline-planner",
  "outline-reviewer",
  "detail-planner",
  "detail-reviewer",
]);

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

let agentType;
try {
  const parsed = JSON.parse(readStdin());
  agentType = parsed && parsed.agent_type;
} catch (e) {
  // fail-open: treat parse errors as {} (agentType stays undefined)
}

const lines = [];
try {
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
} catch (_e) { /* fail-open */ }

// PLAN_LANG only for whitelisted planner/reviewer agents (fail-open: skip on
// unknown/absent agent_type — backstop is check-plan-lang.js PostToolUse).
try {
  if (PLAN_AGENTS.has(agentType)) {
    const planLang = getPlanLangInjection();
    if (planLang) lines.push(planLang);
  }
} catch (_e) { /* fail-open */ }

// Every agent type, gated only on CODEGRAPH=on.
try {
  if (codegraphEnabled()) lines.push(CODEGRAPH_POINTER);
} catch (_e) { /* fail-open */ }

if (lines.length === 0) {
  console.log("{}");
} else {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "SubagentStart",
      additionalContext: lines.join("\n"),
    },
  }));
}
