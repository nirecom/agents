#!/usr/bin/env node
// Claude Code UserPromptSubmit hook: proactive language-directive injection.
//
// Every turn: inject the CONV_LANG directive (conversation reply language).
// During planning turns (clarify_intent / outline / detail not yet resolved):
// also inject the PLAN_LANG directive (plan-artifact language).
//
// Fail-open: any error → emit {} and exit 0.

const fs = require("fs");
const { getConvLangInjection } = require("./lib/conv-lang");
const { getPlanLangInjection } = require("./lib/lang-config");
const { resolveSessionId, readState } = require("./lib/workflow-state");

const PLAN_STEPS = ["clarify_intent", "outline", "detail"];

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

// Planning context = any planning step still pending/in_progress (not
// complete and not skipped). Fail-open to false on state-read failure.
function isPlanning(sessionId) {
  if (!sessionId) return false;
  try {
    const state = readState(sessionId);
    if (!state || !state.steps) return false;
    return PLAN_STEPS.some((step) => {
      const s = (state.steps[step] || {}).status || "pending";
      return s !== "complete" && s !== "skipped";
    });
  } catch (e) {
    return false;
  }
}

function main() {
  let sessionId;
  try {
    const parsed = JSON.parse(readStdin());
    sessionId = (parsed && parsed.session_id) || resolveSessionId();
  } catch (e) {
    try { sessionId = resolveSessionId(); } catch (_e) { sessionId = undefined; }
  }

  const lines = [];

  try {
    const convLang = getConvLangInjection();
    if (convLang) lines.push(convLang);
  } catch (_e) { /* fail-open */ }

  try {
    if (isPlanning(sessionId)) {
      const planLang = getPlanLangInjection();
      if (planLang) lines.push(planLang);
    }
  } catch (_e) { /* fail-open */ }

  if (lines.length === 0) {
    console.log("{}");
    return;
  }
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: lines.join("\n"),
    },
  }));
}

try {
  main();
} catch (_e) {
  // Full fail-open: any unexpected error → emit {} and exit 0.
  console.log("{}");
}

module.exports = { isPlanning };
