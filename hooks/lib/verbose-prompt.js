"use strict";
// Read-side provider for model-conditional prompt hardening (#1611), shaped
// exactly like ./conv-lang.js: pure functions, no side effects, one caller-
// agnostic string. Living in hooks/ rather than rules/ means the text costs
// zero context while the flag is off — rules/*.md would load unconditionally
// into every session.
//
// Consumers: hooks/session-start.js, hooks/post-compact.js.

const { readState, SESSION_ID_VALID_RE } = require("../workflow-state");

// The single definition of the hardening line. One sentence covering the five
// observed failure modes: skipped skill steps, summarizing over a prescribed
// command's output, editing append-only documents directly, dispatching the wrong
// subagent_type, and drafting plans outside PLAN_LANG (#2278). It must never be
// copied anywhere else (CPR-SSOT, pinned by a drift check in the tests).
const VERBOSE_PROMPT_TEXT =
  "Follow every skill step literally and in order: never replace a step's prescribed command output with your own summary, never edit append-only documents directly, always pass the exact subagent_type a skill names when dispatching an agent, and write every planning artifact in the PLAN_LANG language from the first draft.";

function isUsableSessionId(sessionId) {
  return typeof sessionId === "string" && SESSION_ID_VALID_RE.test(sessionId);
}

// The hardening line when this session's frozen flag says so, else null.
// Read-only: never resolves, never persists.
function getVerbosePromptInjection(sessionId) {
  try {
    if (!isUsableSessionId(sessionId)) return null;
    const state = readState(sessionId);
    if (!state || state.verbose_prompt !== true) return null;
    return VERBOSE_PROMPT_TEXT;
  } catch (_) {
    return null;
  }
}

module.exports = {
  VERBOSE_PROMPT_TEXT,
  getVerbosePromptInjection,
};
