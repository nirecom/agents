"use strict";

// Stage 3 of the state-file migration chain: a v2 stream written BEFORE the
// `write_code` step existed becomes a v3 stream that accounts for it (#1665).
//
// WHY a schema version rather than a read-time default: "does this file's
// writer know about `write_code`?" is a property of the FILE, and the only
// field that can carry it is `version`. #1665 inserted `write_code` into
// VALID_STEPS between `review_tests` and `run_tests`; a session that was
// already past `run_tests` when the new code landed has no `write_code`
// step_status event at all, so the projection defaults it to `pending` and
// next-step reports `run_tests is complete but write_code is pending` — an
// abort on a perfectly healthy session. Stamping v3 is how a file declares
// "my writer knew", and this stage is what raises everything older.
//
// The conversion is a PURE function of its input — no clock, no randomness, no
// filesystem — so two processes migrating the same file agree byte-for-byte and
// `seq` stays a shared identifier for the same event. `v2State` is never
// mutated (normalizeStateVersion's contract).

const ORIGIN = "migration-v2-to-v3";
const BACKFILL_STEP = "write_code";

// The stream already mentions the step ⇒ its writer knew about it (or a human
// operated it deliberately, e.g. RESET_FROM). Either way this stage keeps its
// hands off: a single step_status event for `write_code`, of ANY status, is
// enough evidence. Annotations alone are not — they can be attached to a step
// that was never run.
function mentionsWriteCode(events) {
  for (const e of events) {
    if (e && typeof e === "object" && e.kind === "step_status" && e.step === BACKFILL_STEP) return true;
  }
  return false;
}

// True when at least one step AFTER `write_code` is settled. VALID_STEPS is the
// only order authority (CPR-SSOT) — no local order table. The verdict is taken
// on the FOLD, not on raw events: a later event may have reopened a step, and
// only the fold knows the standing status.
function settledDownstreamOfWriteCode(state) {
  // Lazy requires mirror v1-to-v2.js: this module is loaded from within
  // core.js's own normalizeStateVersion, so both are resolvable by call time
  // while a top-level require could observe a half-initialized core.js.
  const { VALID_STEPS, isSettledStatus } = require("../core");
  const { projectState } = require("../projection");
  const first = VALID_STEPS.indexOf(BACKFILL_STEP);
  if (first === -1) return false;
  const steps = projectState(state).steps || {};
  for (let i = first + 1; i < VALID_STEPS.length; i++) {
    const entry = steps[VALID_STEPS[i]];
    if (entry && isSettledStatus(entry.status)) return true;
  }
  return false;
}

// migrateV2ToV3(v2State) -> a fresh v3 state object.
function migrateV2ToV3(v2State) {
  const src = JSON.parse(JSON.stringify(v2State));
  src.version = 3;
  if (!Array.isArray(src.events)) return src;

  if (mentionsWriteCode(src.events)) return src;
  if (!settledDownstreamOfWriteCode(src)) {
    // Nothing downstream is settled, so `write_code` is legitimately still
    // ahead of this session (e.g. it stopped at write_tests). Fabricating a
    // completion here would skip the step for real work that has not happened.
    return src;
  }

  // The session demonstrably ran the implementation body — downstream steps
  // signed off on code that exists — but the writer had no step to record it
  // against. Reconstructing that one fact is exactly what
  // `provenance: "backfilled"` means.
  const createdAt =
    typeof src.created_at === "string" && src.created_at ? src.created_at : "1970-01-01T00:00:00.000Z";
  const last = src.events[src.events.length - 1];
  const lastSeq = last && typeof last === "object" && Number.isFinite(last.seq) ? last.seq : src.events.length;
  // No observation timestamp exists for a step that was never recorded, so the
  // reconstruction shape is v1-to-v2.js's: a stand-in `at` plus at_estimated.
  // The stand-in is the LAST event's own `at`, not created_at: appendEvents
  // always stamps `now`, so a stream is naturally non-decreasing in `at`, and a
  // tail record dated back at session start would be the only one to break that.
  // It is also the closer estimate — the implementation body necessarily ran
  // before the downstream step that settled on top of it.
  const lastAt = last && typeof last === "object" && typeof last.at === "string" && last.at ? last.at : null;
  src.events.push({
    kind: "step_status",
    step: BACKFILL_STEP,
    status: "complete",
    at: lastAt || createdAt,
    at_estimated: true,
    provenance: "backfilled",
    origin: ORIGIN,
    seq: lastSeq + 1,
  });
  return src;
}

module.exports = { migrateV2ToV3 };
