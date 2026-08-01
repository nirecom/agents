"use strict";
// Core state file I/O: step vocabulary, path resolution, read/write, and markStep.
// Entrypoint-private to state-io.js.
//
// Since #1733 the state file is an append-only event stream: `events` is the
// only source of truth (CPR-2) and every derived view is folded from it by
// projection.js. `markStep` is a thin appender; nothing rewrites history.

const fs = require("fs");
const os = require("os");
const path = require("path");
// execFileSync, never execSync: since #1733 these git calls receive a path that
// came from TOOL INPUT (postuse-native-worktree-record passes tool_input.path),
// and a shell would expand `$(...)` / backticks inside it. Argv form has no shell.
const { execFileSync } = require("child_process");
const { withStateLock } = require("./state-lock");
const { normalizeCwd } = require("../../lib/path-normalize");
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
const SKIPPABLE_STEPS = ["clarify_intent", "research", "outline", "detail", "write_tests", "review_tests", "review_security", "cleanup"];
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

// The highest `version` this release can read and write. A file above it was
// written by a newer release and is opaque here.
const MAX_KNOWN_STATE_VERSION = 2;

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
  if (rawState.version === 2) return rawState;
  if (typeof rawState.version === "number" && rawState.version > MAX_KNOWN_STATE_VERSION) {
    throw new FutureSchemaVersionError(rawState.version);
  }
  // `version` was added after the first releases: a file with no marker at all
  // (or a number below the current one) is v1 by content, so dispatch on
  // "is it v2", never on "is it v1".
  const { migrateV1ToV2 } = require("./migrations");
  return migrateV1ToV2(rawState);
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
// Mutates `projection.steps` in place; must run BEFORE guardProjection.
function applyLegacyV1ReadDefaults(rawState, projection) {
  if (!rawState || rawState.version === 2) return projection;
  const legacy = rawState.steps;
  if (!legacy || typeof legacy !== "object" || Array.isArray(legacy)) return projection;
  const steps = projection && projection.steps;
  if (!steps) return projection;

  const setStatus = (step, status) => {
    if (!steps[step]) steps[step] = { status: "pending", updated_at: null };
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

// Rewrite an on-disk v1 file in its v2 form. Idempotent, and fails open when
// the lock cannot be taken — a state file that is being written right now is
// already being brought forward by whoever holds the lock.
function persistMigratedState(sessionId) {
  try {
    return withStateLock(sessionId, () => {
      const raw = readRawState(sessionId);
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) return false;
      // Re-checked INSIDE the lock: a concurrent migrator may have won the race,
      // and re-migrating v2 data would clobber events appended since.
      if (raw.version === 2) return false;
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
    version: 2,
    session_id: sessionId,
    created_at: new Date().toISOString(),
    // The context the session STARTED in. Later movement is recorded as
    // worktree events, so this field never changes after init (CPR-3).
    session_start_context: {
      cwd: ctx && typeof ctx.cwd === "string" ? ctx.cwd : null,
      git_branch: ctx && ctx.git_branch !== undefined ? ctx.git_branch : null,
    },
    workflow_type: "wf-code",
    events: [],
  };
}

// getCurrentContext(dir) -> { cwd, git_branch }.
// With no argument the behaviour is exactly the pre-#1733 one (back-compat for
// session-start.js and friends). With `dir` given, the POSIX drive-letter form
// (`/c/...` from Git Bash / MSYS2) is normalized first, because `git -C` and the
// fs APIs below cannot use it on win32 (rules/coding/nodejs.md).
function getCurrentContext(dir) {
  const base = normalizeCwd(dir) || dir || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const cwd = path.resolve(base);
  let git_branch = null;
  try {
    const out = execFileSync(
      "git",
      ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
      { encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"] }
    );
    git_branch = out.trim() || null;
    if (git_branch === "HEAD") git_branch = null;
  } catch (e) {}
  return { cwd, git_branch };
}

// resolveWorktreeContext(rawPath) -> the fields a `worktree` event needs.
// `path_source` records HOW the path was obtained (CPR-3): a path read from
// tool input is evidence, a process cwd is a guess, and the two must never be
// conflated downstream.
//
// A path is only trusted as `tool_input` when EVERY link of the chain holds:
//   1. a non-empty string that normalizes to an ABSOLUTE path,
//   2. that path exists and is a directory,
//   3. `git -C <path> rev-parse --git-dir` succeeds.
// Any failure falls through to the process-cwd fallback with worktree_path:null —
// recording the hook's own cwd as "the worktree that was entered" would be a
// confident-looking lie. FAILS OPEN on every branch: this never throws.
function resolveWorktreeContext(rawPath) {
  try {
    if (typeof rawPath === "string" && rawPath.trim()) {
      const normalized = normalizeCwd(rawPath.trim());
      if (typeof normalized === "string" && path.isAbsolute(normalized)) {
        const p = path.resolve(normalized);
        if (fs.statSync(p).isDirectory()) {
          execFileSync("git", ["-C", p, "rev-parse", "--git-dir"], {
            encoding: "utf8",
            timeout: 2000,
            stdio: ["pipe", "pipe", "pipe"],
          });
          const ctx = getCurrentContext(p);
          return { cwd: ctx.cwd, git_branch: ctx.git_branch, worktree_path: p, path_source: "tool_input" };
        }
      }
    }
  } catch (e) {
    /* fall through to the fallback below */
  }
  const ctx = getCurrentContext();
  return { cwd: ctx.cwd, git_branch: ctx.git_branch, worktree_path: null, path_source: "fallback-process-cwd" };
}

// markStep(sessionId, stepName, status, extraFields, opts)
// Signature preserved from the pre-#1733 keyed-map implementation; the body is
// now a single append. Each extra field becomes its own step_annotation event,
// so a later annotation never has to rewrite the status record.
function markStep(sessionId, stepName, status, extraFields = {}, opts = {}) {
  const { appendEvents } = require("./events");
  const provenance = typeof opts.provenance === "string" ? opts.provenance : "observed";
  const origin = typeof opts.origin === "string" ? opts.origin : "mark-step";
  const events = [{ kind: "step_status", step: stepName, status, provenance, origin }];
  if (extraFields && typeof extraFields === "object") {
    for (const key of Object.keys(extraFields)) {
      // started_at was retired with #1640; a caller cannot reintroduce it.
      if (key === "started_at") continue;
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
