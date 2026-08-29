"use strict";
// Top-level (non-step) session field writers, plus the effective skippable-step view.
// Entrypoint-private to state-io.js.

const { SKIPPABLE_STEPS, readState, readRawState, normalizeStateVersion, updateTopLevel } = require("./core");
const { appendEvents } = require("./events");
const { withStateLock } = require("./state-lock");
const { deriveAggregateLevel, deriveStageLevels, canonicalizeSignalsForPersistence } = require("../complexity-routing");

// recordComplexityEvaluation(sessionId, signals):
// Session-scoped fact, recorded as its own event (#1733) — a re-evaluation
// supersedes the previous one in the projection without erasing it.
// Write path — no fail-open: caller passes SIGNALS only (#2099); level and
// levels are derived here so they can never disagree with the input signals.
// RoutingTableUnavailableError propagates to the caller, who owns fail-open.
// Returns the persisted { level, levels, signals } so callers can echo/verify
// the SAME canonicalized signals actually written (#2099 LI-3/LI-6).
function recordComplexityEvaluation(sessionId, signals) {
  if (arguments.length > 2) {
    throw new Error(
      "recordComplexityEvaluation(sessionId, level, signals) is removed — pass (sessionId, signals) only"
    );
  }
  // Fed to derivation RAW (not pre-normalized): a non-array signals value must
  // reach deriveAggregateLevel/deriveStageLevels as-is so their own
  // !Array.isArray(...) fail-high branch (detail.md D1 step 3) actually fires.
  // Normalizing to [] here first would make every malformed input look like a
  // valid zero-signal call and silently route to low instead of high.
  const level = deriveAggregateLevel(signals);
  const levels = Object.assign({}, deriveStageLevels(signals));
  // The PERSISTED signals field is canonicalized independently of the
  // derivation outcome above (#2099 H-SIG/LI-3/LI-6) — see
  // canonicalizeSignalsForPersistence for the exact rule.
  const list = canonicalizeSignalsForPersistence(signals);
  appendEvents(sessionId, [
    {
      kind: "complexity_evaluation",
      level,
      levels,
      signals: list,
      provenance: "observed",
      origin: "record-complexity-evaluation",
      at: new Date().toISOString(),
    },
  ]);
  return { level, levels, signals: list };
}

// readLastRawComplexityEvent(sessionId):
// Read-back VERIFICATION only (#2099). Returns the most recent
// complexity_evaluation event's raw persisted fields with NO projection folding
// and NO compat completion — a `levels` that was never written comes back
// undefined, which is the whole point: the consumer-facing
// readComplexityEvaluation() would reconstruct it and mask a persistence bug.
// Never use this on a normal consumer path.
function readLastRawComplexityEvent(sessionId) {
  const raw = readRawState(sessionId);
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const state = normalizeStateVersion(raw);
  if (!state || !Array.isArray(state.events)) return null;
  for (let i = state.events.length - 1; i >= 0; i--) {
    const e = state.events[i];
    if (e && typeof e === "object" && e.kind === "complexity_evaluation") {
      return { level: e.level, levels: e.levels, signals: e.signals, recorded_at: e.at };
    }
  }
  return null;
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
  readLastRawComplexityEvent,
  recordSessionModel,
  setLastPushedSha,
  clearLastPushedSha,
  recordSessionWorktree,
  getSkippableSteps,
};
