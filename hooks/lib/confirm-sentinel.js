"use strict";
// hooks/lib/confirm-sentinel.js — finds a CONFIRM_{INTENT,OUTLINE,DETAIL} sentinel in a raw command.
// Shared by confirm-checkpoint.js (the dialog) and plan-link-turn-check.js, so both agree on what
// counts as a CONFIRM. The patterns are owned by sentinel-patterns.js; a raw command is not a lone
// echo, so the SSOT regex is reused with its `^echo "` / `"$` anchors dropped (#2256 S1-a).

const sentinelPatterns = require("./sentinel-patterns");

function unanchoredEcho(re) {
  return new RegExp(re.source.replace(/^\^echo "/, "").replace(/"\$$/, ""));
}

// Keyed by the workflow step (#2820); a caller needing the plan artifact name uses rowFor(step).suffix.
const CONFIRM_STEP_PATTERNS = [
  { step: "clarify_intent", re: unanchoredEcho(sentinelPatterns.CONFIRM_INTENT_LOOKSLIKE_RE) },
  { step: "outline", re: unanchoredEcho(sentinelPatterns.CONFIRM_OUTLINE_LOOKSLIKE_RE) },
  { step: "detail", re: unanchoredEcho(sentinelPatterns.CONFIRM_DETAIL_LOOKSLIKE_RE) },
];

// parseSentinel(command) -> { step } or null when no CONFIRM sentinel matches.
function parseSentinel(command) {
  if (typeof command !== "string" || command.length === 0) return null;
  for (const entry of CONFIRM_STEP_PATTERNS) {
    if (entry.re.test(command)) return { step: entry.step };
  }
  return null;
}

module.exports = { CONFIRM_STEP_PATTERNS, parseSentinel };
