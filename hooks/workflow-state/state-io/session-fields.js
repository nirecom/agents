"use strict";
// Top-level (non-step) session field writers, plus the effective skippable-step view.
// Entrypoint-private to state-io.js.

const {
  SKIPPABLE_STEPS,
  readState,
  writeState,
  createInitialState,
} = require("./core");

// recordComplexityEvaluation(sessionId, level, signals):
// Top-level field writer (does NOT go through markStep). Read-modify-write.
// Write path — no fail-open: an invalid level throws.
function recordComplexityEvaluation(sessionId, level, signals) {
  let state = readState(sessionId);
  if (!state) {
    state = createInitialState(sessionId);
  }
  if (level !== "high" && level !== "low") {
    throw new Error(`recordComplexityEvaluation: level must be "high" or "low", got ${JSON.stringify(level)}`);
  }
  state.complexity_evaluation = {
    recorded_at: new Date().toISOString(),
    level,
    signals: Array.isArray(signals) ? signals : [],
  };
  writeState(sessionId, state);
}

// recordSessionModel(sessionId, { modelId | id, source }):
// Top-level field writer (like recordComplexityEvaluation). Read-modify-write.
// Freezes the session's model identity ONCE — re-invocation must not overwrite
// an already-recorded identity — and decides `verbose_prompt` in the same transaction so the
// flag and the identity can never disagree.
// The identifier key is accepted as `modelId` or `id`: resolveModelId() returns
// the `{ id, source }` shape and is passed straight through by SessionStart.
// Returns { recorded, verbosePrompt }. Write errors propagate to the caller,
// which is responsible for failing open.
function recordSessionModel(sessionId, descriptor) {
  const d = descriptor && typeof descriptor === "object" ? descriptor : {};
  const rawId = typeof d.modelId === "string" && d.modelId.trim() ? d.modelId : d.id;
  const modelId = typeof rawId === "string" && rawId.trim() ? rawId.trim() : null;
  if (!modelId) return { recorded: false, verbosePrompt: false };

  let state = readState(sessionId);
  if (!state) {
    state = createInitialState(sessionId);
  }
  // Write-once: must not turn into last-writer-wins.
  if (state.session_model) {
    return { recorded: false, verbosePrompt: state.verbose_prompt === true };
  }

  let verbosePrompt = false;
  try {
    require("../../lib/load-env").loadDefaultEnv();
    const { matchKeyword, parseKeywordList } = require("../../lib/model-match");
    verbosePrompt =
      matchKeyword(modelId, parseKeywordList(process.env.VERBOSE_PROMPT_MODELS)) !== null;
  } catch (_) {
    verbosePrompt = false;
  }

  state.session_model = {
    id: modelId,
    source: typeof d.source === "string" && d.source ? d.source : "unknown",
    recorded_at: new Date().toISOString(),
  };
  state.verbose_prompt = verbosePrompt;
  // readState adds skip_judgment as a convenience view only; writing it back
  // would persist it permanently.
  delete state.skip_judgment;
  writeState(sessionId, state);
  return { recorded: true, verbosePrompt };
}

function setLastPushedSha(sessionId, sha) {
  const state = readState(sessionId);
  if (!state) return false;
  state.last_pushed_sha = sha;
  writeState(sessionId, state);
  return true;
}

function clearLastPushedSha(sessionId) {
  const state = readState(sessionId);
  if (!state) return false;
  state.last_pushed_sha = null;
  writeState(sessionId, state);
  return true;
}

function recordSessionWorktree(sessionId, worktreePath) {
  const state = readState(sessionId);
  if (!state) return;
  state.session_worktree = worktreePath;
  writeState(sessionId, state);
}

// Returns the effective skippable steps for the given session.
// BUGFIX sessions exclude write_tests and review_tests (T0-A gate).
// Lazy require avoids circular dependency with is-bugfix-session.js.
function getSkippableSteps(sessionId) {
  try {
    const { isBugfixSession } = require("../is-bugfix-session");
    if (isBugfixSession({ sessionId })) {
      return SKIPPABLE_STEPS.filter(s => s !== "write_tests" && s !== "review_tests");
    }
  } catch (_) {}
  return SKIPPABLE_STEPS;
}

module.exports = {
  recordComplexityEvaluation,
  recordSessionModel,
  setLastPushedSha,
  clearLastPushedSha,
  recordSessionWorktree,
  getSkippableSteps,
};
