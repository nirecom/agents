"use strict";

// Stage 3 of the state-file migration chain: a v2 stream written before the
// `write_code` step existed becomes a v3 stream that accounts for it.
//
// A session that was already past `run_tests` when `write_code` was inserted
// into VALID_STEPS has no `write_code` step_status event at all, so the
// projection defaults it to `pending` and next-step aborts a perfectly healthy
// session. Stamping v3 is how a file declares "my writer knew about
// write_code", and this stage is what raises older files to that state.
//
// The conversion is a pure function of its input (no clock, no randomness, no
// filesystem) so two processes migrating the same file agree byte-for-byte and
// `seq` stays a shared identifier for the same event. `v2State` is never
// mutated (normalizeStateVersion's contract).

const ORIGIN = "migration-v2-to-v3";
const BACKFILL_STEP = "write_code";

// The stream already mentions the step ⇒ its writer knew about it (or a human
// operated it deliberately, e.g. RESET_FROM) — this stage keeps its hands off.
// Annotations alone are not enough evidence; they can attach to a step that
// was never run.
function mentionsWriteCode(events) {
  for (const e of events) {
    if (e && typeof e === "object" && e.kind === "step_status" && e.step === BACKFILL_STEP) return true;
  }
  return false;
}

// True when at least one step AFTER `write_code` is settled, per the fold (not
// raw events — a later event may have reopened a step).
function settledDownstreamOfWriteCode(state) {
  // Lazy require: this module loads from within core.js's own
  // normalizeStateVersion, so a top-level require could see a half-init core.js.
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
  // Nothing settled downstream ⇒ write_code is legitimately still ahead of
  // this session; fabricating a completion would skip real unfinished work.
  if (!settledDownstreamOfWriteCode(src)) return src;

  const createdAt =
    typeof src.created_at === "string" && src.created_at ? src.created_at : "1970-01-01T00:00:00.000Z";
  const last = src.events[src.events.length - 1];
  const lastSeq = last && typeof last === "object" && Number.isFinite(last.seq) ? last.seq : src.events.length;
  // Stand-in timestamp is the last event's own `at` (falls back to createdAt):
  // appendEvents always stamps `now`, so `at` is non-decreasing across a
  // stream, and this is also the closer estimate of when write_code ran.
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
