#!/usr/bin/env node
// Claude Code SubagentStart hook: inject conversation language directive into subagent context

const { readHookInput } = require("./lib/read-stdin");
const { getConvLangInjection } = require("./lib/conv-lang");
const { getPlanLangInjection } = require("./lib/lang-config");
const { codegraphEnabled } = require("./lib/codegraph-boundary");

// The same nudge the nine adopting agents/*.md carry, extended to every
// subagent — built-in Explore/general-purpose/Plan agents included.
const CODEGRAPH_NUDGE =
  "Before a Read/Grep sweep of unfamiliar code, try `mcp__codegraph__codegraph_explore` first — usage and the projectPath caveat: agents/lib/codegraph-usage.md";

// Drain stdin so the parent never sees a closed pipe; only session_id is read from the payload,
// for the VERBOSE_PROMPT flag of the (parent) session. A broken payload injects no VERBOSE_PROMPT.
let sessionId = null;
try {
  const r = readHookInput();
  if (r.kind === "ok" && r.input && typeof r.input.session_id === "string") sessionId = r.input.session_id;
} catch (_e) { /* fail-open */ }

const lines = [];
try {
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
} catch (_e) { /* fail-open */ }

// Every agent type receives the PLAN_LANG directive when the policy is not noop —
// mirrors the codegraph nudge below. Rescues general-purpose mis-dispatch (#2278).
try {
  const planLang = getPlanLangInjection();
  if (planLang) lines.push(planLang);
} catch (_e) { /* fail-open */ }

try {
  const { getVerbosePromptInjection } = require("./lib/verbose-prompt");
  const verbosePrompt = getVerbosePromptInjection(sessionId);
  if (verbosePrompt) lines.push(verbosePrompt);
} catch (_e) { /* fail-open */ }

// Every agent type, gated only on CODEGRAPH=on.
try {
  if (codegraphEnabled()) lines.push(CODEGRAPH_NUDGE);
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
