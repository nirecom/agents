"use strict";
// Read-side provider for model-conditional prompt hardening (#1611), shaped
// exactly like ./conv-lang.js: pure functions, no side effects, one caller-
// agnostic string. Living in hooks/ rather than rules/ means the text costs
// zero context while the flag is off — rules/*.md would load unconditionally
// into every session.
//
// Consumers: hooks/session-start.js, hooks/post-compact.js, and
// bin/record-session-model.js (which injects on the recording turn itself).

const path = require("path");
const { readState, SESSION_ID_VALID_RE } = require("./workflow-state");
const { loadDefaultEnv } = require("./load-env");
const { parseKeywordList } = require("./model-match");

// The single definition of the hardening line. One sentence covering the three
// observed failure modes: skipped skill steps, summarizing over a prescribed
// command's output, and editing append-only documents directly. It must never
// be copied anywhere else (CPR-2, pinned by a drift check in the tests).
const VERBOSE_PROMPT_TEXT =
  "Follow every skill step literally and in order: never replace a step's prescribed command output with your own summary, and never edit append-only documents directly.";

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

// Layer③ bootstrap: ask the model to self-report once, but only while the
// feature is configured AND nothing has been recorded yet. Both conditions off
// means zero added context, which is the whole point of gating here.
function getModelSelfReportRequest(sessionId) {
  try {
    if (!isUsableSessionId(sessionId)) return null;
    loadDefaultEnv();
    if (parseKeywordList(process.env.VERBOSE_PROMPT_MODELS).length === 0) return null;

    const state = readState(sessionId);
    if (state && state.session_model) return null;

    const agentsDir = process.env.AGENTS_CONFIG_DIR || path.join(__dirname, "..", "..");
    const cli = path.join(agentsDir, "bin", "record-session-model.js");
    return (
      `Run this once now, before anything else: node "${cli}" --session ${sessionId} ` +
      `--self-report-text "<the sentence in your system prompt that names the model you are powered by>"`
    );
  } catch (_) {
    return null;
  }
}

module.exports = {
  VERBOSE_PROMPT_TEXT,
  getVerbosePromptInjection,
  getModelSelfReportRequest,
};
