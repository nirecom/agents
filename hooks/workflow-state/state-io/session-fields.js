"use strict";
// Top-level (non-step) session field writers, plus the effective skippable-step view.
// Entrypoint-private to state-io.js.

const { SKIPPABLE_STEPS, readState, updateTopLevel } = require("./core");
const { appendEvents } = require("./events");
const { withStateLock } = require("./state-lock");

// recordComplexityEvaluation(sessionId, level, signals):
// Session-scoped fact, recorded as its own event (#1733) — a re-evaluation
// supersedes the previous one in the projection without erasing it.
// Write path — no fail-open: an invalid level throws.
function recordComplexityEvaluation(sessionId, level, signals) {
  if (level !== "high" && level !== "low") {
    throw new Error(`recordComplexityEvaluation: level must be "high" or "low", got ${JSON.stringify(level)}`);
  }
  appendEvents(sessionId, [
    {
      kind: "complexity_evaluation",
      level,
      signals: Array.isArray(signals) ? signals : [],
      provenance: "observed",
      origin: "record-complexity-evaluation",
    },
  ]);
}

// recordSessionModel(sessionId, { modelId | id, source }):
// Freezes the session's model identity ONCE — re-invocation must not overwrite
// an already-recorded identity — and decides `verbose_prompt` in the same transaction so the
// flag and the identity can never disagree. The write-once decision is taken
// INSIDE the state lock (#1733): checked outside it, two racing SessionStart
// processes would each observe "no identity yet" and both append one.
// The identifier key is accepted as `modelId` or `id`: resolveModelId() returns
// the `{ id, source }` shape and is passed straight through by SessionStart.
// Returns { recorded, verbosePrompt }. Write errors propagate to the caller,
// which is responsible for failing open.
function recordSessionModel(sessionId, descriptor) {
  const d = descriptor && typeof descriptor === "object" ? descriptor : {};
  const rawId = typeof d.modelId === "string" && d.modelId.trim() ? d.modelId : d.id;
  const modelId = typeof rawId === "string" && rawId.trim() ? rawId.trim() : null;
  if (!modelId) return { recorded: false, verbosePrompt: false };

  return withStateLock(sessionId, () => {
    const state = readState(sessionId);
    // Write-once: must not turn into last-writer-wins.
    if (state && state.session_model) {
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

    appendEvents(sessionId, [
      {
        kind: "session_model",
        id: modelId,
        source: typeof d.source === "string" && d.source ? d.source : "unknown",
        provenance: "observed",
        origin: "record-session-model",
      },
    ]);
    // verbose_prompt is a decision, not a derived value, so it stays a persisted
    // top-level field — written under the same lock as the identity it follows.
    updateTopLevel(sessionId, (record) => {
      record.verbose_prompt = verbosePrompt;
    });
    return { recorded: true, verbosePrompt };
  });
}

// The three writers below own ONE non-derived top-level field each. updateTopLevel
// does the read-modify-write under the lock and touches nothing else, so a
// concurrent append can no longer be lost to a stale whole-state snapshot.
function setLastPushedSha(sessionId, sha) {
  if (!readState(sessionId)) return false;
  updateTopLevel(sessionId, (record) => {
    record.last_pushed_sha = sha;
  });
  return true;
}

function clearLastPushedSha(sessionId) {
  if (!readState(sessionId)) return false;
  updateTopLevel(sessionId, (record) => {
    record.last_pushed_sha = null;
  });
  return true;
}

function recordSessionWorktree(sessionId, worktreePath) {
  if (!readState(sessionId)) return;
  updateTopLevel(sessionId, (record) => {
    record.session_worktree = worktreePath;
  });
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
