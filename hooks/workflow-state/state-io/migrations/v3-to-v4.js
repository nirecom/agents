"use strict";

// Stage 4 of the state-file migration chain: a v3 stream written before the
// `review_docs` step existed becomes a v4 stream that accounts for it.
// review_docs sits between `docs` and `user_verification`; a session past
// `docs` when it was inserted has no review_docs event, so the projection
// defaults it to `pending` and next-step aborts a healthy session. This stage
// mirrors migrateV2ToV3: pure function of its input (no clock/RNG/fs), and
// `v3State` is never mutated (normalizeStateVersion's contract).

const ORIGIN = "migration-v3-to-v4";
const BACKFILL_STEP = "review_docs";

// The stream already mentions the step ⇒ its writer knew about it (or a human
// operated it deliberately) — keep hands off.
function mentionsReviewDocs(events) {
  for (const e of events) {
    if (e && typeof e === "object" && e.kind === "step_status" && e.step === BACKFILL_STEP) return true;
  }
  return false;
}

// True when at least one step AFTER `review_docs` is settled, per the fold.
function settledDownstreamOfReviewDocs(state) {
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

// migrateV3ToV4(v3State) -> a fresh v4 state object.
function migrateV3ToV4(v3State) {
  const src = JSON.parse(JSON.stringify(v3State));
  src.version = 4;
  if (!Array.isArray(src.events)) return src;

  if (mentionsReviewDocs(src.events)) return src;
  // Nothing settled downstream ⇒ review_docs is legitimately still ahead of
  // this session; fabricating a completion would skip real unfinished review.
  if (!settledDownstreamOfReviewDocs(src)) return src;

  const createdAt =
    typeof src.created_at === "string" && src.created_at ? src.created_at : "1970-01-01T00:00:00.000Z";
  const last = src.events[src.events.length - 1];
  const lastSeq = last && typeof last === "object" && Number.isFinite(last.seq) ? last.seq : src.events.length;
  // Stand-in timestamp is the last event's own `at` (falls back to createdAt).
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

module.exports = { migrateV3ToV4 };
