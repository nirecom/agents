"use strict";

// Derived read model over the append-only `events` stream (#1733).
//
// `events` is the single source of truth (CPR-SSOT). Everything a reader used to
// find at the top level of the state file — `steps`, `plan_approvals`,
// `git_branch`, ... — is *derived* here by folding the stream, never stored
// independently. `current` on disk is a cache of this fold, rewritten from
// scratch on every persist, and is never read back as authority.

const PROJECTION_KEYS = [
  "complexity_evaluation",
  "cwd",
  "git_branch",
  "is_bugfix",
  "plan_approvals",
  "session_model",
  "skip_judgment",
  "steps",
  "worktree_entered_at",
  "worktree_exited_at",
];

// Allowlist of everything that may be persisted at the top level of a v2 state
// file, in canonical serialization order. Fail-closed: an unrecognized key
// aborts the write rather than being silently dropped or silently kept.
const PERSISTED_TOP_LEVEL_KEYS = [
  "version",
  "session_id",
  "created_at",
  "session_start_context",
  "workflow_type",
  "closes_issues",
  "last_pushed_sha",
  "session_worktree",
  "verbose_prompt",
  "merge_base_baseline",
  "events",
  "current",
];

class UnknownStateKeyError extends Error {
  constructor(message) {
    super(message);
    this.name = "UnknownStateKeyError";
  }
}

class ProjectionMutatedError extends Error {
  constructor(message) {
    super(message);
    this.name = "ProjectionMutatedError";
  }
}

// A stream whose records could only exist via out-of-band editing: `seq` is
// assigned by appendEvents alone (1-based, contiguous over the whole array),
// and every event it writes already carries a validated `provenance` and (for
// step_status) a validated `status` (events.js validateEvent()). A record that
// fails any of those checks proves the file was tampered with after the fact,
// so the fold must not report ANY status derived from it as trustworthy —
// see X11 in tests/feature-1733-state-event-stream/robustness.sh.
class StreamIntegrityError extends Error {
  constructor(message) {
    super(message);
    this.name = "StreamIntegrityError";
  }
}

const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

// One of THREE sites that hand-build a step entry (the others: the
// step_annotations_cleared rebuild below, and applyLegacyV1ReadDefaults in
// core.js). They are deliberately NOT unified behind a shared helper — the
// core.js one lives inside a temporary migration block slated for wholesale
// deletion — so their key-set parity is pinned by test instead
// (tests/feature-1665-seq-cascade/b-entry-shape-parity.sh). Adding a field here
// without adding it to the other two produces entries whose `updated_seq` reads
// `undefined`, which silently defeats the write-code resume cascade (CPR-ORTH).
function emptyStepEntry() {
  return { status: "pending", updated_at: null, updated_seq: null };
}

// Throws StreamIntegrityError when `events` could not have been produced by
// appendEvents alone. Pure and read-only.
function assertStreamIntegrity(events) {
  // Lazy requires avoid a load-time cycle: projection.js <-> events.js/core.js.
  const { PROVENANCE_VALUES } = require("./events");
  const { VALID_STATUSES } = require("./core");
  let expectedSeq = 1;
  for (const e of events) {
    if (!e || typeof e !== "object") {
      throw new StreamIntegrityError("event stream contains a non-object record");
    }
    if (e.seq !== expectedSeq) {
      throw new StreamIntegrityError("event stream seq is not a contiguous 1-based sequence");
    }
    expectedSeq += 1;
    if (typeof e.provenance !== "string" || !PROVENANCE_VALUES.includes(e.provenance)) {
      throw new StreamIntegrityError("event has a missing or invalid provenance");
    }
    if (e.kind === "step_status" && !VALID_STATUSES.includes(e.status)) {
      throw new StreamIntegrityError("event has an invalid status");
    }
  }
}

// Fold the event stream into the read model. Pure: never touches the filesystem
// and never mutates `state`.
//
// Deliberately does NOT run assertStreamIntegrity itself: appendEvents folds a
// BATCH whose new events have no `seq` yet (assignment happens after the fold
// decides what to append — see events.js), so a blanket check here would
// reject every legitimate append. Callers that fold a stream claiming to be
// the durable on-disk truth (readState, appendEvents' pre-append check) call
// assertStreamIntegrity themselves first.
//
// INVARIANT — `updated_seq` is the FOLD LOOP POSITION (`i + 1`), never `e.seq`.
// The two are equivalent by definition for a durable stream: appendEvents
// assigns `merged[i].seq = i + 1` over the whole array (events.js), and
// assertStreamIntegrity enforces that equivalence as tamper detection. Reading
// `e.seq` here would nonetheless be WRONG, because appendEvents folds the
// withBatch stream through this function BEFORE it assigns seq — so the very
// events a decision depends on would project `undefined`. Non-object records
// are skipped
// with `continue` but still consume a position, matching the seq assignment.
//
// INVARIANT — role separation of the two per-entry axes:
//   `updated_at`  — WALL-CLOCK only. Answers "how long ago?" (elapsed time).
//                   Useless for ordering: a single batch stamps every one of its
//                   events with the same `at`.
//   `updated_seq` — CAUSAL ORDER only. Answers "before or after?" Never used to
//                   measure elapsed time.
// Neither may substitute for the other.
function projectState(state) {
  const events = state && Array.isArray(state.events) ? state.events : [];
  const ctx = (state && state.session_start_context) || {};

  const { VALID_STEPS } = require("./core");
  const steps = {};
  for (const step of VALID_STEPS) steps[step] = emptyStepEntry();

  const plan_approvals = {};
  let worktree_entered_at = null;
  let worktree_exited_at = null;
  let session_model = null;
  let complexity_evaluation = null;
  let worktreeBranch = null;
  let worktreeCwd = null;

  for (let i = 0; i < events.length; i++) {
    const e = events[i];
    if (!e || typeof e !== "object") continue;
    switch (e.kind) {
      case "step_status": {
        if (!steps[e.step]) steps[e.step] = emptyStepEntry();
        steps[e.step].status = e.status;
        steps[e.step].updated_at = e.at !== undefined ? e.at : null;
        // Position, NOT e.seq — see the INVARIANT note on projectState.
        steps[e.step].updated_seq = i + 1;
        break;
      }
      case "step_annotation": {
        if (!steps[e.step]) steps[e.step] = emptyStepEntry();
        // A null-valued annotation is a tombstone: the key disappears from the
        // projection while the event itself stays in the stream.
        if (e.value === null) delete steps[e.step][e.key];
        else steps[e.step][e.key] = e.value;
        break;
      }
      case "step_annotations_cleared": {
        // Rebuild carrying STRUCTURE only. `updated_seq` is structure, not an
        // annotation: dropping it here would wipe the causal axis on every
        // annotation clear (RESET_FROM included).
        const entry = steps[e.step];
        if (entry) {
          steps[e.step] = {
            status: entry.status,
            updated_at: entry.updated_at,
            updated_seq: entry.updated_seq,
          };
        }
        break;
      }
      case "worktree": {
        if (e.transition === "entered") {
          worktree_entered_at = e.at !== undefined ? e.at : null;
          worktree_exited_at = null;
          if (e.git_branch !== undefined) worktreeBranch = e.git_branch;
          if (e.cwd !== undefined) worktreeCwd = e.cwd;
        } else if (e.transition === "exited") {
          worktree_exited_at = e.at !== undefined ? e.at : null;
        }
        break;
      }
      case "session_model": {
        // Write-once by contract: the first recording wins.
        if (!session_model) {
          session_model = { id: e.id, source: e.source, recorded_at: e.at !== undefined ? e.at : null };
        }
        break;
      }
      case "complexity_evaluation": {
        complexity_evaluation = {
          level: e.level,
          signals: Array.isArray(e.signals) ? e.signals.slice() : [],
          recorded_at: e.at !== undefined ? e.at : null,
        };
        break;
      }
      case "plan_approval": {
        plan_approvals[e.step] = {
          source: e.source,
          reason: e.reason,
          artifact_sha256: e.artifact_sha256,
          artifact_session_id: e.artifact_session_id,
          artifact_hash_status: e.artifact_hash_status,
          recorded_at: e.at !== undefined ? e.at : null,
        };
        break;
      }
      case "plan_approval_revoked": {
        delete plan_approvals[e.step];
        break;
      }
      default:
        break;
    }
  }

  const git_branch = worktreeBranch !== null ? worktreeBranch : ctx.git_branch !== undefined ? ctx.git_branch : null;
  const cwd = worktreeCwd !== null ? worktreeCwd : ctx.cwd !== undefined ? ctx.cwd : null;

  // Convenience view: skip_judgment keyed by step name, so callers can read
  // projection.skip_judgment[step] instead of projection.steps[step].skip_judgment.
  const skip_judgment = {};
  for (const step of Object.keys(steps)) {
    const sj = steps[step].skip_judgment;
    if (sj) skip_judgment[step] = sj;
  }

  // Lazy require avoids a cycle: is-bugfix-session → state-io → projection.
  const { isBugfixBranch } = require("../is-bugfix-session");

  return {
    complexity_evaluation,
    cwd,
    git_branch,
    is_bugfix: isBugfixBranch(git_branch),
    plan_approvals,
    session_model,
    skip_judgment,
    steps,
    worktree_entered_at,
    worktree_exited_at,
  };
}

function refuseWrite(prop) {
  throw new TypeError(
    `workflow state projection is read-only (attempted write to "${String(prop)}"); it is derived from events`
  );
}

// Prototype that refuses the creation of a NEW key. An own non-writable property
// is only silently rejected outside strict mode, so existing keys are guarded by
// throwing setters (below) and unknown keys fall through to this trap.
const REFUSING_PROTO = new Proxy(Object.create(null), {
  set(target, prop) {
    return refuseWrite(prop);
  },
  has() {
    return false;
  },
  get() {
    return undefined;
  },
});

// Make the projection read-only all the way down.
//
// Object.freeze alone is not enough: ~20 pre-#1733 readers write into
// `state.steps`, and outside strict mode a write to a frozen object is a SILENT
// no-op — exactly the failure mode this migration must not introduce. Accessor
// properties with throwing setters fail LOUDLY in both modes while remaining
// ordinary objects, so `structuredClone` still produces the documented mutable
// copy (a Proxy would not be cloneable).
function guardProjection(value) {
  if (!value || typeof value !== "object") return value;
  if (Array.isArray(value)) return Object.freeze(value.map(guardProjection));
  const guarded = Object.create(REFUSING_PROTO);
  for (const key of Object.keys(value)) {
    const child = guardProjection(value[key]);
    Object.defineProperty(guarded, key, {
      get: () => child,
      set: () => refuseWrite(key),
      enumerable: true,
      configurable: false,
    });
  }
  Object.preventExtensions(guarded);
  return guarded;
}

// Shallow copy of `state` with every derived key removed. What remains is the
// candidate persisted record.
function stripProjection(state) {
  const out = {};
  if (!state || typeof state !== "object") return out;
  for (const key of Object.keys(state)) {
    if (PROJECTION_KEYS.includes(key)) continue;
    out[key] = state[key];
  }
  return out;
}

// A caller that reassigns a top-level projection key on a state object handed
// out by readState is writing to a derived view; the write would be silently
// discarded, so refuse instead.
function assertProjectionUnmutated(state) {
  const snapshot = state && state.__projectionSnapshot;
  if (!snapshot || typeof snapshot !== "object") return;
  for (const key of PROJECTION_KEYS) {
    if (state[key] !== snapshot[key]) {
      throw new ProjectionMutatedError(
        `workflow state projection key "${key}" was reassigned; the projection is derived from events and cannot be written directly`
      );
    }
  }
}

// Serialize to the exact bytes that belong on disk. Throws before any I/O
// happens when the record carries a key outside the allowlist.
function serializeStateForPersist(state) {
  const stripped = stripProjection(state);
  const unknown = Object.keys(stripped).filter((k) => !PERSISTED_TOP_LEVEL_KEYS.includes(k));
  if (unknown.length > 0) {
    // Name the KEY only — the value may carry session content.
    throw new UnknownStateKeyError(
      `unknown top-level workflow state key(s): ${unknown.sort().join(", ")}`
    );
  }
  // Lazy require avoids a load-time cycle: core.js requires this module at its
  // top level, so a top-level `require("./core")` here would see an empty export.
  const { CURRENT_STATE_VERSION } = require("./core");
  const out = { version: CURRENT_STATE_VERSION };
  for (const key of PERSISTED_TOP_LEVEL_KEYS) {
    if (key === "version" || key === "current") continue;
    if (hasOwn(stripped, key)) out[key] = stripped[key];
  }
  if (!Array.isArray(out.events)) out.events = [];
  out.current = projectState(out);
  return JSON.stringify(out, null, 2);
}

module.exports = {
  PROJECTION_KEYS,
  PERSISTED_TOP_LEVEL_KEYS,
  UnknownStateKeyError,
  ProjectionMutatedError,
  StreamIntegrityError,
  assertStreamIntegrity,
  projectState,
  guardProjection,
  stripProjection,
  assertProjectionUnmutated,
  serializeStateForPersist,
};
