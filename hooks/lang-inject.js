#!/usr/bin/env node
// Claude Code UserPromptSubmit hook: proactive language-directive injection.
//
// Every turn: inject the CONV_LANG directive (conversation reply language).
// During planning turns (clarify_intent / outline / detail not yet resolved):
// also inject the PLAN_LANG directive (plan-artifact language).
//
// Fail-open: any error → emit {} and exit 0.

const { getConvLangInjection } = require("./lib/conv-lang");
const { getPlanLangInjection } = require("./lib/lang-config");
const { resolveSessionId } = require("./workflow-state");
const { readHookInput } = require("./lib/read-stdin");
const { isPlanning } = require("./lib/planning-phase");

function main() {
  let sessionId;
  try {
    const r = readHookInput();
    if (r.kind !== "ok") throw r.error || new Error(r.kind);
    const parsed = r.input;
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
