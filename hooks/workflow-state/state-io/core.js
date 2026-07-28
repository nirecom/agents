"use strict";
// Core state file I/O: step vocabulary, path resolution, read/write, and markStep.
// Entrypoint-private to state-io.js. Must not require any sibling submodule other
// than ./migrations — the siblings require this file, so the reverse edge would
// close a cycle.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");
const { recordStepTimestampsEnabled, applyStartedAt } = require("../step-timestamps");
const { applyStateMigrations } = require("./migrations");

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
];
const SKIPPABLE_STEPS = ["clarify_intent", "research", "outline", "detail", "write_tests", "review_tests", "review_security", "cleanup"];
const VALID_STATUSES = ["pending", "in_progress", "complete", "skipped"];

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

function readState(sessionId) {
  try {
    const filePath = getStatePath(sessionId);
    const raw = fs.readFileSync(filePath, "utf8");
    const state = JSON.parse(raw);
    return applyStateMigrations(state);
  } catch (e) {
    return null;
  }
}

// writeState(sessionId, state, opts):
//   opts.sanctioned : one of completion-approval.SANCTIONED_SOURCES. Bypasses the
//                     approval invariant and stamps an audit record instead.
//   opts.reason     : free text recorded on a stamped audit record.
//
// Failure contract: readState stays FAIL-OPEN, but writeState is FAIL-CLOSED for
// the completion-boundary invariant below — an unapproved completion of a gated
// step throws UnapprovedCompletionError and nothing is persisted. (Same precedent
// as recordComplexityEvaluation, which throws on an invalid level.)
function writeState(sessionId, state, opts = {}) {
  // Lazy require avoids a circular dependency: completion-approval → state-io.
  require("../completion-approval").applyCompletionBoundaryInvariant(sessionId, state, opts);
  const workflowDir = getWorkflowDir();
  fs.mkdirSync(workflowDir, { recursive: true });
  const filePath = getStatePath(sessionId);
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, JSON.stringify(state, null, 2), "utf8");
  fs.renameSync(tmpPath, filePath);
}

function createInitialState(sessionId, ctx) {
  const steps = {};
  for (const step of VALID_STEPS) {
    steps[step] = { status: "pending", updated_at: null };
  }
  const state = {
    version: 1,
    session_id: sessionId,
    created_at: new Date().toISOString(),
    steps,
  };
  if (ctx && typeof ctx === "object") {
    if (typeof ctx.cwd === "string") state.cwd = ctx.cwd;
    state.git_branch = ctx.git_branch ?? null;
    // Lazy require avoids circular dependency: is-bugfix-session → state-io → is-bugfix-session.
    const { isBugfixBranch } = require("../is-bugfix-session");
    state.is_bugfix = isBugfixBranch(state.git_branch);
  }
  state.workflow_type = "wf-code";
  state.complexity_evaluation = null;
  return state;
}

function getCurrentContext() {
  const cwd = path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd());
  let git_branch = null;
  try {
    const out = execSync(
      `git -C ${JSON.stringify(cwd)} rev-parse --abbrev-ref HEAD`,
      { encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"] }
    );
    git_branch = out.trim() || null;
    if (git_branch === "HEAD") git_branch = null;
  } catch (e) {}
  return { cwd, git_branch };
}

// opts is passed straight through to writeState (see its contract for
// opts.sanctioned). All pre-existing call sites use <= 4 args.
function markStep(sessionId, stepName, status, extraFields = {}, opts = {}) {
  let state = readState(sessionId);
  if (!state) {
    state = createInitialState(sessionId);
  }
  const now = new Date().toISOString();
  const entry = { status, updated_at: now, ...extraFields };
  if (recordStepTimestampsEnabled()) {
    // started_at is owned by the state layer alone. Applied AFTER the extraFields spread,
    // so a caller cannot forge it. Rule SSOT: workflow-state/step-timestamps.js.
    applyStartedAt(entry, { prev: state.steps[stepName] || null, now });
  } else {
    // Toggle off => `started_at` appears nowhere. The other half of the same ownership:
    // extraFields is caller-supplied, so the off-state is enforced here rather than
    // assumed of every call site.
    delete entry.started_at;
  }
  state.steps[stepName] = entry;
  writeState(sessionId, state, opts);
}

module.exports = {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  VALID_STATUSES,
  getWorkflowDir,
  SESSION_ID_VALID_RE,
  assertValidSessionId,
  getStatePath,
  readState,
  writeState,
  createInitialState,
  getCurrentContext,
  markStep,
};
