"use strict";
// Core state file I/O: step vocabulary, path resolution, read/write, and markStep.
// Entrypoint-private to state-io.js.
//
// Since #1733 the state file is an append-only event stream: `events` is the
// only source of truth (CPR-SSOT) and every derived view is folded from it by
// projection.js. `markStep` is a thin appender; nothing rewrites history.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { withStateLock } = require("./state-lock");
const { getCurrentContext, resolveWorktreeContext } = require("./core/context");
const {
  PROJECTION_KEYS,
  projectState,
  guardProjection,
  stripProjection,
  assertProjectionUnmutated,
  serializeStateForPersist,
  assertStreamIntegrity,
} = require("./projection");

const VALID_STEPS = [
  "workflow_init",
  "clarify_intent",
  "research",
  "outline",
  "detail",
  "branching_complete",
  "write_tests",
  "review_tests",
  "write_code",
  "run_tests",
  "review_security",
  "docs",
  "user_verification",
  "cleanup",
  "pre_final_report_gate",
  "final_report",
];
// SSOT for "the session is over". Anything appended after a terminal step is
// out-of-band bookkeeping and closes no interval (see intervals.js).
const TERMINAL_STEPS = ["final_report"];
// run_tests (#1644) is skippable ONLY through a docs-only-verified door: both
// write sides (not-needed-handlers.js and mark-step-handler.js) check
// isDocsOnlyStaged fail-closed before recording it.
// write_code (#1665) is deliberately absent: the implementation body itself has
// no "not needed" door — a session that changes nothing never reaches it.
const SKIPPABLE_STEPS = ["clarify_intent", "research", "outline", "detail", "write_tests", "review_tests", "run_tests", "review_security", "cleanup"];
const VALID_STATUSES = ["pending", "in_progress", "complete", "skipped"];

// "settled" = the step needs no further action: it is either done ("complete")
// or deliberately opted out of ("skipped"). "pending" and "in_progress" are NOT
// settled — "in_progress" is deliberately excluded because the step is still
// running and further action is expected.
const SETTLED_STATUSES = Object.freeze(["complete", "skipped"]);
function isSettledStatus(status) {
  return SETTLED_STATUSES.indexOf(status) !== -1;
}

function getWorkflowDir() {
  if (process.env.CLAUDE_WORKFLOW_DIR) return process.env.CLAUDE_WORKFLOW_DIR;
  return path.join(os.homedir(), ".claude", "projects", "workflow");
}

// SSOT for sessionId validation (defense-in-depth against path traversal).
// Real session IDs — UUIDs (hex+hyphen), YYYYMMDD-HHMMSS fallbacks (digit+hyphen),
// and test sids ("test-sid-bash-9", "20260509-bundle-a") — all match this regex,
// so legitimate use is never broken. Rejects path separators, "..", and the like.
const SESSION_ID_VALID_RE = /^[A-Za-z0-9_-]+$/;

// Throws on an invalid sessionId. Used by path-building callers where an
// unvalidated sessionId is a caller bug (path traversal), not a recoverable state.
function assertValidSessionId(sessionId) {
  if (typeof sessionId !== "string" || !SESSION_ID_VALID_RE.test(sessionId)) {
    throw new Error(`Invalid sessionId: ${JSON.stringify(sessionId)}`);
  }
}

function getStatePath(sessionId) {
  assertValidSessionId(sessionId);
  return path.join(getWorkflowDir(), sessionId + ".json");
}

// The schema version THIS release writes. SSOT for the single fact "the newest
// on-disk form this code knows how to produce" (CPR-SSOT): createInitialState
// and serializeStateForPersist both stamp it, and MAX_KNOWN_STATE_VERSION is
// derived from it rather than restated. A per-stage migration output version
// (e.g. `{ version: 2 }` in migrations/v1-to-v2.js) is a DIFFERENT fact — that
// stage's own output form — and must stay a literal there.
//
// v3 (#1665) is what a file uses to DECLARE that the code which wrote it knew
// about the `write_code` step; see migrations/v2-to-v3.js.
const CURRENT_STATE_VERSION = 3;

// The highest `version` this release can read and write. A file above it was
// written by a newer release and is opaque here.
const MAX_KNOWN_STATE_VERSION = CURRENT_STATE_VERSION;

// Thrown by readRawState when the file EXISTS but its bytes are not valid
// JSON. Distinct from "no file" (readRawState returns null for that): a
// missing file is nothing to protect, but a corrupt one is the only forensic
// record of whatever produced it, and every writer must refuse to touch it
// rather than silently replacing it with a fresh initial state (X9 in
// tests/feature-1733-state-event-stream/robustness.sh).
class CorruptStateFileError extends Error {
  constructor(message) {
    super(message);
    this.name = "CorruptStateFileError";
  }
}

// Thrown by normalizeStateVersion when a file's `version` is higher than this
// release understands. Such a file was written by a newer release (possibly a
// concurrent session on the same machine after an upgrade) and must never be
// downgraded in place — that would silently drop whatever the newer schema
// added (X10 in tests/feature-1733-state-event-stream/robustness.sh).
class FutureSchemaVersionError extends Error {
  constructor(version) {
    super(`state file has schema version ${version}, newer than this release understands (max known ${MAX_KNOWN_STATE_VERSION})`);
    this.name = "FutureSchemaVersionError";
  }
}

// Raw JSON read without migration or projection. Callers that need to
// distinguish "synthesized by readState" from "genuinely written" use this (#1681).
//
// Returns null when the file does not exist (or is otherwise unreadable) —
// there is nothing to protect. THROWS CorruptStateFileError when the file
// exists but its bytes do not parse as JSON: that is evidence, not absence,
// and every caller must fail closed on it rather than treating it as "no
// state yet".
function readRawState(sessionId) {
  // Resolve OUTSIDE the try: assertValidSessionId rejecting a traversal-shaped id
  // is a caller bug, and swallowing it here would report it as "no state yet".
  const statePath = getStatePath(sessionId);
  let raw;
  try {
    raw = fs.readFileSync(statePath, "utf8");
  } catch (e) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new CorruptStateFileError(`state file for session is not valid JSON`);
  }
}

// Bring any historical on-disk shape up to the current schema, in memory.
// Pure: `rawState` is never mutated and no file is touched. Throws
// FutureSchemaVersionError for a version this release does not know how to
// read — never migrated, never guessed at.
function normalizeStateVersion(rawState) {
  if (!rawState || typeof rawState !== "object" || Array.isArray(rawState)) return rawState;
  if (rawState.version === 3) return rawState;
  if (typeof rawState.version === "number" && rawState.version > MAX_KNOWN_STATE_VERSION) {
    throw new FutureSchemaVersionError(rawState.version);
  }
  // `version` was added after the first releases: a file with no marker at all
  // (or a number below the current one) is v1 by content, so dispatch on
  // "is it vN", never on "is it v1". The stages chain — a v1 file runs through
  // every stage in order, a v2 file joins at the stage that raises it.
  const { migrateV1ToV2, migrateV2ToV3 } = require("./migrations");
  if (rawState.version === 2) return migrateV2ToV3(rawState);
  return migrateV2ToV3(migrateV1ToV2(rawState));
}

// readState(sessionId) -> the persisted record with the derived projection
// attached, or null. FAIL-OPEN: a corrupt or unreadable file yields null and
// never throws, so a gate can decide for itself what an unknown state means.
//
// READ-ONLY, deliberately: a v1 file is normalized in memory but NEVER written
// back. The workflow dir is shared by every session on the machine, and callers
// read foreign session ids out of it (context-scan.js harvests them from other
// sessions' transcripts). A v1 file may belong to a session still running an
// older release that cannot read v2, so migrating it here corrupts that session.
// Bringing a file forward is a WRITER's job: writeState, updateTopLevel, and
// appendEvents all normalize under the state lock before writing, so a file
// migrates the moment its OWN session next writes — the only safe moment.
//
// The projection is deep-frozen and exposed three ways for compatibility with
// pre-#1733 callers: as `state.current`, spliced onto the top level under each
// PROJECTION_KEYS name, and as a non-enumerable `__projectionSnapshot` used by
// writeState to detect a caller that tried to write to the derived view.
// --- BEGIN temporary: pre-workflow_init v1 sessions → v2 read defaults migration ---
// A v1 state file predating a step's introduction simply has NO entry for it, and
// pre-#1733 readers backfilled a status for exactly three of those steps. That
// backfill is a READ-TIME default, not history: the event stream records what a
// session actually did, so the v1→v2 conversion must not fabricate step_status
// events for steps the session never touched (see K-f in
// tests/feature-1733-state-event-stream/migration-annotations.sh). The default is
// therefore applied to the PROJECTION of a record that was v1 on disk, keyed on
// the absence of the key in the v1 `steps` map.
//
// SCOPE BOUNDARY vs the v2→v3 migration stage: this block stays frozen at those
// three v1-only steps and gains no new members. `write_code` (#1665) is missing
// from v2 files too, and a read-time default cannot express "the writer did not
// know this step existed" for a versioned file — that is what a schema version
// is for, so it is resolved in migrations/v2-to-v3.js instead.
//
// Mutates `projection.steps` in place; must run BEFORE guardProjection.
function applyLegacyV1ReadDefaults(rawState, projection) {
  // Keyed on "was v1 on disk": v1 predates the `version` field entirely, so any
  // numeric version (2, 3, ...) is out of scope here.
  if (!rawState || rawState.version >= 2) return projection;
  const legacy = rawState.steps;
  if (!legacy || typeof legacy !== "object" || Array.isArray(legacy)) return projection;
  const steps = projection && projection.steps;
  if (!steps) return projection;

  const setStatus = (step, status) => {
    // Third hand-built step-entry site: its key set must match
    // projection.js emptyStepEntry() exactly (CPR-ORTH; pinned by
    // tests/feature-1665-seq-cascade/b-entry-shape-parity.sh).
    if (!steps[step]) steps[step] = { status: "pending", updated_at: null, updated_seq: null };
    steps[step].status = status;
  };

  const ci = legacy.clarify_intent;
  const ciDone = ci && (ci.status === "complete" || ci.status === "skipped");
  // Sessions predating workflow_init (#1039) were already past routing unless
  // clarify_intent was still in flight at upgrade time.
  if (!legacy.workflow_init) setStatus("workflow_init", (!ci || ciDone) ? "complete" : "pending");
  // Sessions predating clarify_intent / branching_complete never had the step to
  // run, so it cannot be pending against them.
  if (!ci) setStatus("clarify_intent", "complete");
  if (!legacy.branching_complete && !legacy.branching_decision) {
    setStatus("branching_complete", "complete");
  }
  return projection;
}
// --- END temporary: pre-workflow_init v1 sessions → v2 read defaults migration ---

function readState(sessionId) {
  let rawState;
  try {
    rawState = readRawState(sessionId);
  } catch (e) {
    // CorruptStateFileError (or anything else): fail open, touch nothing.
    return null;
  }
  if (!rawState || typeof rawState !== "object" || Array.isArray(rawState)) return null;

  let state;
  try {
    state = normalizeStateVersion(rawState);
  } catch (e) {
    return null;
  }
  if (!state || typeof state !== "object" || !Array.isArray(state.events)) return null;

  let projection;
  try {
    assertStreamIntegrity(state.events);
    projection = guardProjection(applyLegacyV1ReadDefaults(rawState, projectState(state)));
  } catch (e) {
    return null;
  }

  const out = stripProjection(state);
  out.current = projection;
  for (const key of PROJECTION_KEYS) out[key] = projection[key];
  Object.defineProperty(out, "__projectionSnapshot", {
    value: projection,
    enumerable: false,
    writable: false,
    configurable: true,
  });

  return out;
}

// Rewrite an on-disk legacy file in its current-version form. Idempotent, and fails open when
// the lock cannot be taken — a state file that is being written right now is
// already being brought forward by whoever holds the lock.
function persistMigratedState(sessionId) {
  try {
    return withStateLock(sessionId, () => {
      const raw = readRawState(sessionId);
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) return false;
      // Re-checked INSIDE the lock: a concurrent migrator may have won the race,
      // and re-migrating already-current data would clobber events appended since.
      // The test is "is it ALREADY the newest form", so it tracks
      // CURRENT_STATE_VERSION — a v2 file is now itself a migration subject.
      if (raw.version === CURRENT_STATE_VERSION) return false;
      const state = normalizeStateVersion(raw);
      if (!state || !Array.isArray(state.events)) return false;
      writeStateLocked(sessionId, state);
      return true;
    });
  } catch (e) {
    return false;
  }
}

let tmpCounter = 0;

// Persist `state` atomically. MUST be called with the state lock held.
// The temp file name carries pid + a per-process counter so two processes
// cannot collide on it — and so a stray hand-written `<sid>.json.tmp` is never
// touched.
function writeStateLocked(sessionId, state) {
  // Serialize FIRST: an unknown key or an unserializable value must abort
  // before a single byte is written.
  const json = serializeStateForPersist(state);
  const filePath = getStatePath(sessionId);
  fs.mkdirSync(getWorkflowDir(), { recursive: true });
  tmpCounter += 1;
  const tmpPath = `${filePath}.${process.pid}.${tmpCounter}.tmp`;
  try {
    // flag "wx" (O_CREAT|O_EXCL) so a symlink planted at the predictable tmp path
    // fails with EEXIST instead of being followed — same discipline as state-lock.
    try {
      fs.writeFileSync(tmpPath, json, { encoding: "utf8", flag: "wx" });
    } catch (e) {
      if (e && e.code === "EEXIST") {
        fs.unlinkSync(tmpPath);
        fs.writeFileSync(tmpPath, json, { encoding: "utf8", flag: "wx" });
      } else {
        throw e;
      }
    }
    fs.renameSync(tmpPath, filePath);
  } catch (e) {
    try {
      fs.unlinkSync(tmpPath);
    } catch (e2) {
      /* nothing to clean up */
    }
    throw e;
  }
}

// writeState(sessionId, state, opts):
//   opts.sanctioned : one of completion-approval.SANCTIONED_SOURCES. Bypasses the
//                     approval invariant and stamps an audit record instead.
//   opts.reason     : free text recorded on a stamped audit record.
//
// Failure contract: readState stays FAIL-OPEN, but writeState is FAIL-CLOSED —
// a mutated projection, an unknown top-level key, or an unapproved completion of
// a gated step all throw with ZERO bytes changed.
function writeState(sessionId, state, opts = {}) {
  assertProjectionUnmutated(state);
  // Lazy require avoids a circular dependency: completion-approval → state-io.
  require("../completion-approval").applyCompletionBoundaryInvariant(sessionId, state, opts);
  return withStateLock(sessionId, () => {
    const record = stripProjection(state);
    // `events` is append-only and owned by appendEvents. A caller that read the
    // state before taking the lock may hold a stale stream, so the on-disk one
    // always wins — otherwise a concurrent append would be lost.
    const disk = readRawState(sessionId);
    if (disk && typeof disk === "object" && !Array.isArray(disk)) {
      const norm = normalizeStateVersion(disk);
      if (norm && Array.isArray(norm.events)) record.events = norm.events;
    }
    writeStateLocked(sessionId, record);
  });
}

// updateTopLevel(sessionId, patchFn): read-modify-write of the non-derived top
// level under the lock. `patchFn` receives the persisted record only — writing
// a derived key on it is a no-op, writing an unlisted key throws.
function updateTopLevel(sessionId, patchFn) {
  return withStateLock(sessionId, () => {
    const raw = readRawState(sessionId);
    let state = raw && typeof raw === "object" && !Array.isArray(raw) ? normalizeStateVersion(raw) : null;
    if (!state || typeof state !== "object") state = createInitialState(sessionId, getCurrentContext());
    if (!Array.isArray(state.events)) state.events = [];
    const record = stripProjection(state);
    patchFn(record);
    writeStateLocked(sessionId, record);
    return record;
  });
}

function createInitialState(sessionId, ctx) {
  return {
    version: CURRENT_STATE_VERSION,
    session_id: sessionId,
    created_at: new Date().toISOString(),
    // The context the session STARTED in. Later movement is recorded as
    // worktree events, so this field never changes after init (CPR-SC).
    session_start_context: {
      cwd: ctx && typeof ctx.cwd === "string" ? ctx.cwd : null,
      git_branch: ctx && ctx.git_branch !== undefined ? ctx.git_branch : null,
    },
    workflow_type: "wf-code",
    events: [],
  };
}

// getCurrentContext / resolveWorktreeContext: moved to ./core/context.js
// (file-split.md) — re-exported below for state-io.js barrel compatibility.

// markStep(sessionId, stepName, status, extraFields, opts)
// Signature preserved from the pre-#1733 keyed-map implementation; the body is
// now a single append. Each extra field becomes its own step_annotation event,
// so a later annotation never has to rewrite the status record.
function markStep(sessionId, stepName, status, extraFields = {}, opts = {}) {
  const { appendEvents, RESERVED_ANNOTATION_KEYS } = require("./events");
  const provenance = typeof opts.provenance === "string" ? opts.provenance : "observed";
  const origin = typeof opts.origin === "string" ? opts.origin : "mark-step";
  const events = [{ kind: "step_status", step: stepName, status, provenance, origin }];
  if (extraFields && typeof extraFields === "object") {
    for (const key of Object.keys(extraFields)) {
      // Structure keys are never annotations. Silently skipped rather than
      // thrown: callers pass whole entry-shaped objects here, and the
      // `started_at` precedent (retired with #1640) already set that contract.
      if (RESERVED_ANNOTATION_KEYS.includes(key)) continue;
      events.push({
        kind: "step_annotation",
        step: stepName,
        key,
        value: extraFields[key] === undefined ? null : extraFields[key],
        provenance,
        origin,
      });
    }
  }
  appendEvents(sessionId, events, opts);
}

module.exports = {
  VALID_STEPS,
  TERMINAL_STEPS,
  SKIPPABLE_STEPS,
  VALID_STATUSES,
  CURRENT_STATE_VERSION,
  MAX_KNOWN_STATE_VERSION,
  CorruptStateFileError,
  FutureSchemaVersionError,
  isSettledStatus,
  getWorkflowDir,
  SESSION_ID_VALID_RE,
  assertValidSessionId,
  getStatePath,
  readState,
  readRawState,
  normalizeStateVersion,
  persistMigratedState,
  writeState,
  writeStateLocked,
  updateTopLevel,
  createInitialState,
  getCurrentContext,
  resolveWorktreeContext,
  markStep,
};
