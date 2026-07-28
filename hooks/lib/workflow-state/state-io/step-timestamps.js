"use strict";
// SSOT for the optional `started_at` field on workflow step objects — metric (c) of the
// lightweight measurement set. The rule lives here and nowhere else: every write path into
// state.steps[*] calls into this module rather than restating the rule.
//
// THE INVARIANT (this is the definition of the feature, not a transition rule):
//
//   toggle on  => every step whose status is non-`pending` (in_progress / complete /
//                 skipped) HAS `started_at`, and every `pending` step has NONE.
//   toggle off => `started_at` appears nowhere; the state file is byte-identical to what
//                 the same session produced before this feature existed.
//
// `started_at` is ATTEMPT-scoped: returning a step to `pending` loses it, and the next
// non-pending write starts a new interval. It is stated as an invariant on the state
// rather than as a rule about transitions because a transition rule silently misses any
// path that writes a step object without going through markStep.
//
// Two writers exist. markStep carries an existing value forward. reset-handler.js
// regenerates the steps before the reset target as `complete` with a synthetic
// `updated_at`, and passes `prev: null` so `started_at` is synthesised the same way: the
// original completion time is already gone there, and keeping a real past `started_at`
// beside a synthetic `updated_at` would report "original start .. reset time" as if it
// were a duration. `started_at === updated_at` (zero elapsed) is therefore the readable
// signature of a DECLARED completion rather than an observed one.
//
// `skipped` is non-pending, so it is stamped too and likewise reads as zero elapsed.

// Resolved once per process, so the state layer never pays for the toggle twice.
let _enabled = null;

/**
 * True when RECORD_STEP_TIMESTAMPS is on.
 *
 * The value is resolved at most once per process and cached, so flipping the env var
 * mid-process has no effect — hooks are short-lived processes, but tests must either use
 * one process per toggle value or call _resetStepTimestampsToggleCache().
 *
 * An explicit (non-empty) env value settles the question on its own and `load-env` is
 * never consulted: workflow hooks call loadDefaultEnv() at their entry point, so the value
 * is normally already in process.env by the time a step is marked. Only `on`
 * (case-insensitive, trimmed) enables the feature; unset, empty, and anything else are off.
 */
function recordStepTimestampsEnabled() {
  if (_enabled !== null) return _enabled;
  let raw = process.env.RECORD_STEP_TIMESTAMPS;
  if (typeof raw !== "string" || raw === "") {
    try {
      require("../../load-env").loadDefaultEnv();
    } catch (_) {
      // fail-safe: an unreadable .env leaves the feature off
    }
    raw = process.env.RECORD_STEP_TIMESTAMPS;
  }
  _enabled = String(raw == null ? "" : raw).trim().toLowerCase() === "on";
  return _enabled;
}

// Test-only: drop the cached toggle so the next call re-resolves it.
function _resetStepTimestampsToggleCache() {
  _enabled = null;
}

/**
 * Apply the invariant to one step entry and return it. The caller decides whether the
 * feature is on (this function has the single responsibility of the rule itself).
 *
 * `prev` is the step object being replaced, or null to force a synthetic value.
 */
function applyStartedAt(entry, { prev, now }) {
  if (entry.status === "pending") return entry;
  const carried =
    prev && prev.status !== "pending" && typeof prev.started_at === "string" && prev.started_at
      ? prev.started_at
      : null;
  entry.started_at = carried === null ? now : carried;
  return entry;
}

module.exports = {
  recordStepTimestampsEnabled,
  _resetStepTimestampsToggleCache,
  applyStartedAt,
};
