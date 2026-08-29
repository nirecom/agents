"use strict";

// Event vocabulary and the single append path for the workflow state stream (#1733).
//
// `appendEvents` is the ONLY function permitted to add to `state.events`.
// Everything else derives from the stream (see projection.js). Appending is
// deliberately dumb: no dedup, no coalescing, no rewriting of history — a
// repeated fact is a repeated event, and the fold decides what it means.

const { withStateLock } = require("./state-lock");
const { projectState, assertStreamIntegrity } = require("./projection");

const EVENT_KINDS = [
  "step_status",
  "step_annotation",
  "step_annotations_cleared",
  "worktree",
  "session_model",
  "complexity_evaluation",
  "plan_approval",
  "plan_approval_revoked",
  "reset",
];

// How much the recorded `at` can be trusted:
//   observed    — the process saw the fact happen and stamped it then
//   declared    — a caller asserted the fact; the timestamp is the assertion's
//   backfilled  — reconstructed after the fact (schema migration, repair)
const PROVENANCE_VALUES = ["observed", "declared", "backfilled"];

// Provenance values that represent a GENUINELY recorded fact — i.e. NOT
// reconstructed by migration/session-inheritance. Used wherever code must
// distinguish "this session actually observed/declared this" from "this was
// backfilled from somewhere else" (#1794).
const GENUINE_PROVENANCE = PROVENANCE_VALUES.filter((p) => p !== "backfilled");

function isGenuineProvenance(provenance) {
  return GENUINE_PROVENANCE.includes(provenance);
}

// Known annotation keys, in table order. Unknown keys are NOT rejected — the
// table drives ordering and documentation only, so a newly introduced key
// still round-trips verbatim instead of being dropped.
const STEP_ANNOTATION_KEYS = [
  "token",
  "wsid",
  "warnings_summary",
  "warnings_accepted_reason",
  "invalidate_reason",
  "skip_reason",
  "skip_verdict",
  "skip_judgment",
  "reset_reason",
  "run_outcome",
];

// Step-entry fields that are STRUCTURE, never annotation. An annotation named
// after any of them would overwrite a projected fact with caller-supplied data —
// for `updated_seq` that means forging the causal position the write-code resume
// cascade trusts. Reserved at three sites with deliberately different refusals
// (CPR-ORTH): validateEvent throws, markStep's extraFields silently skips, and
// the v1 entry converter drops (ENTRY_META_KEYS in migrations/v1-to-v2.js —
// throwing there would abort a whole inheritance batch).
const RESERVED_ANNOTATION_KEYS = ["status", "updated_at", "started_at", "updated_seq"];

const WORKTREE_TRANSITIONS = ["entered", "exited"];

// Where a recorded worktree path came from. Kept explicit (CPR-SC) so a path
// observed from tool input is never confused with a process-cwd guess.
const PATH_SOURCES = ["tool_input", "fallback-process-cwd", "prior-entry", "migration-unknown"];

const REQUIRED_FIELDS = {
  step_status: ["step", "status"],
  step_annotation: ["step", "key", "value"],
  step_annotations_cleared: ["step"],
  worktree: ["transition", "git_branch", "cwd", "worktree_path", "path_source"],
  session_model: ["id", "source"],
  complexity_evaluation: ["level", "signals"],
  plan_approval: [
    "step",
    "source",
    "reason",
    "artifact_sha256",
    "artifact_session_id",
    "artifact_hash_status",
  ],
  plan_approval_revoked: ["step", "reason"],
  reset: ["from_step", "reason"],
};

class InvalidEventError extends Error {
  constructor(message) {
    super(message);
    this.name = "InvalidEventError";
  }
}

const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

// Throws InvalidEventError when `event` is not a well-formed stream record.
// Error messages name FIELDS, never values — values carry session content.
function validateEvent(event) {
  if (!event || typeof event !== "object" || Array.isArray(event)) {
    throw new InvalidEventError("event must be a plain object");
  }
  if (typeof event.kind !== "string" || !EVENT_KINDS.includes(event.kind)) {
    throw new InvalidEventError("event.kind is missing or outside EVENT_KINDS");
  }
  if (typeof event.provenance !== "string" || !PROVENANCE_VALUES.includes(event.provenance)) {
    throw new InvalidEventError(`event.provenance is missing or outside PROVENANCE_VALUES (kind=${event.kind})`);
  }
  if (typeof event.origin !== "string" || event.origin.length === 0) {
    throw new InvalidEventError(`event.origin is missing (kind=${event.kind})`);
  }
  for (const field of REQUIRED_FIELDS[event.kind]) {
    if (!hasOwn(event, field) || event[field] === undefined) {
      throw new InvalidEventError(`event.${field} is required for kind=${event.kind}`);
    }
  }

  const { VALID_STEPS, VALID_STATUSES } = require("./core");
  if (hasOwn(event, "step") && !VALID_STEPS.includes(event.step)) {
    throw new InvalidEventError(`event.step is outside VALID_STEPS (kind=${event.kind})`);
  }
  if (hasOwn(event, "from_step") && !VALID_STEPS.includes(event.from_step)) {
    throw new InvalidEventError(`event.from_step is outside VALID_STEPS (kind=${event.kind})`);
  }
  if (event.kind === "step_status" && !VALID_STATUSES.includes(event.status)) {
    throw new InvalidEventError("event.status is outside VALID_STATUSES");
  }
  if (event.kind === "step_annotation") {
    if (typeof event.key !== "string" || event.key.length === 0) {
      throw new InvalidEventError("event.key must be a non-empty string");
    }
    if (RESERVED_ANNOTATION_KEYS.includes(event.key)) {
      throw new InvalidEventError(`event.key "${event.key}" is reserved and cannot be an annotation`);
    }
  }
  if (event.kind === "worktree") {
    if (!WORKTREE_TRANSITIONS.includes(event.transition)) {
      throw new InvalidEventError("event.transition must be one of: " + WORKTREE_TRANSITIONS.join(", "));
    }
    if (!PATH_SOURCES.includes(event.path_source)) {
      throw new InvalidEventError("event.path_source must be one of: " + PATH_SOURCES.join(", "));
    }
  }
  if (event.kind === "complexity_evaluation") {
    if (!Array.isArray(event.signals)) {
      throw new InvalidEventError("event.signals must be an array");
    }
    // `levels` stays OPTIONAL (REQUIRED_FIELDS is unchanged) so pre-#2099 and
    // migration-backfilled events still append; when present it must be exact.
    if (event.levels !== undefined) {
      const { ROUTING_STAGES } = require("../complexity-routing");
      const lv = event.levels;
      if (!lv || typeof lv !== "object" || Array.isArray(lv)) {
        throw new InvalidEventError("event.levels must be a plain object (kind=complexity_evaluation)");
      }
      const lvKeys = Object.keys(lv);
      if (lvKeys.length !== ROUTING_STAGES.length || !ROUTING_STAGES.every((s) => lvKeys.includes(s))) {
        throw new InvalidEventError("event.levels keys must be exactly ROUTING_STAGES (kind=complexity_evaluation)");
      }
      for (const stage of ROUTING_STAGES) {
        if (lv[stage] !== "high" && lv[stage] !== "low") {
          throw new InvalidEventError(`event.levels.${stage} must be "high" or "low"`);
        }
      }
    }
  }
  return event;
}

// appendEvents(sessionId, eventsOrBuilder, opts) -> the full events array.
//
// `eventsOrBuilder` may be an event object, an array of them, or a function
// `(events, current) => event|events`. The builder form is evaluated INSIDE the
// lock, after the state file has been re-read, so a decision that depends on
// the current stream cannot be made against a stale snapshot.
function appendEvents(sessionId, eventsOrBuilder, opts = {}) {
  const core = require("./core");
  return withStateLock(
    sessionId,
    () => {
      const raw = core.readRawState(sessionId);
      let state = raw && typeof raw === "object" && !Array.isArray(raw) ? core.normalizeStateVersion(raw) : null;
      if (!state || typeof state !== "object") {
        state = core.createInitialState(sessionId, core.getCurrentContext());
      }
      if (!Array.isArray(state.events)) state.events = [];
      // Refuse to build on a stream that could not have come from appendEvents
      // alone (out-of-band seq gap/dup/reorder or a hand-edited event record) —
      // THROWS here, before anything is written, so the broken evidence stays
      // on disk untouched (X5 in tests/feature-1733-state-event-stream/robustness.sh).
      assertStreamIntegrity(state.events);

      let produced = eventsOrBuilder;
      if (typeof eventsOrBuilder === "function") {
        produced = eventsOrBuilder(state.events.slice(), projectState(state));
      }
      if (produced === null || produced === undefined) produced = [];
      if (!Array.isArray(produced)) produced = [produced];
      if (produced.length === 0) return state.events;

      const now = typeof opts.now === "string" && opts.now ? opts.now : new Date().toISOString();
      const built = produced.map((partial) => {
        const event = Object.assign({}, partial);
        if (typeof event.at !== "string" || event.at.length === 0) event.at = now;
        validateEvent(event);
        return event;
      });

      // Completion-boundary invariant (#1133) — evaluated HERE because appendEvents
      // is the only remaining write path: a gated step reaching `complete` without a
      // recorded approval must be refused before any byte is written. The verdict is
      // taken on the fold BEFORE the batch vs the fold WITH it, so a batch that both
      // approves and completes in one shot is judged as a whole.
      // Lazy require avoids a circular dependency: completion-approval → state-io.
      const withBatch = Object.assign({}, state, { events: state.events.concat(built) });
      const boundaryEvents = require("../completion-approval").completionBoundaryEventsForBatch(
        sessionId,
        projectState(state),
        projectState(withBatch),
        opts
      );
      for (const partial of boundaryEvents) {
        const event = Object.assign({}, partial);
        if (typeof event.at !== "string" || event.at.length === 0) event.at = now;
        validateEvent(event);
        built.push(event);
      }

      // seq is assigned here and nowhere else: 1-based and contiguous over the
      // whole stream, so a gap or a duplicate is detectable as corruption.
      const merged = state.events.concat(built);
      for (let i = 0; i < merged.length; i++) {
        if (merged[i] && typeof merged[i] === "object") merged[i].seq = i + 1;
      }
      state.events = merged;
      core.writeStateLocked(sessionId, state);
      return state.events;
    },
    opts
  );
}

module.exports = {
  EVENT_KINDS,
  PROVENANCE_VALUES,
  GENUINE_PROVENANCE,
  isGenuineProvenance,
  STEP_ANNOTATION_KEYS,
  RESERVED_ANNOTATION_KEYS,
  WORKTREE_TRANSITIONS,
  PATH_SOURCES,
  REQUIRED_FIELDS,
  InvalidEventError,
  validateEvent,
  appendEvents,
};
