"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");

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
    if (state && state.steps) {
      if (state.steps.verify && !state.steps.run_tests) {
        state.steps.run_tests = state.steps.verify;
      }
      delete state.steps.verify;
      delete state.steps.code;
      if (!state.steps.run_tests) {
        state.steps.run_tests = { status: "pending", updated_at: null };
      }
      if (!state.steps.review_security) {
        state.steps.review_security = { status: "pending", updated_at: null };
      }
      // migration: sessions predating review_tests (issue #833) start it pending.
      if (!state.steps.review_tests) {
        state.steps.review_tests = { status: "pending", updated_at: null };
      }
      // --- BEGIN temporary: old sessions → workflow_init migration (added 2026-05-14) ---
      const ci = state.steps.clarify_intent;
      const ciDone = ci && (ci.status === "complete" || ci.status === "skipped");
      if (!state.steps.workflow_init) {
        state.steps.workflow_init = {
          status: (!ci || ciDone) ? "complete" : "pending",
          updated_at: null,
        };
      }
      // --- END temporary: old sessions → workflow_init migration ---
      if (!state.steps.clarify_intent) {
        state.steps.clarify_intent = { status: "complete", updated_at: null };
      }
      // migration: branching_decision → branching_complete rename
      if (state.steps.branching_decision && !state.steps.branching_complete) {
        state.steps.branching_complete = state.steps.branching_decision;
      }
      delete state.steps.branching_decision;
      if (!state.steps.branching_complete) {
        state.steps.branching_complete = { status: "complete", updated_at: null };
      }
      // --- BEGIN temporary: plan → outline+detail migration (added 2026-05-23, #485) ---
      if (state.steps.plan) {
        const src = state.steps.plan;
        if (!state.steps.outline) state.steps.outline = { ...src };
        if (!state.steps.detail)  state.steps.detail  = { ...src };
        delete state.steps.plan;
      }
      // --- END temporary: plan → outline+detail migration ---
      if (!state.steps.cleanup) {
        state.steps.cleanup = { status: "pending", updated_at: null };
      }
      if (!state.workflow_type) {
        state.workflow_type = "wf-code";
      }
      // migration: wf-plan → wf-meta rename
      if (state.workflow_type === "wf-plan") {
        state.workflow_type = "wf-meta";
      }
      // Convenience view: top-level skip_judgment map keyed by step name.
      // Allows callers to access state.skip_judgment[step] instead of
      // state.steps[step].skip_judgment. Read-only; not persisted.
      state.skip_judgment = {};
      for (const step of Object.keys(state.steps)) {
        const sj = state.steps[step] && state.steps[step].skip_judgment;
        if (sj) state.skip_judgment[step] = sj;
      }
    }
    return state;
  } catch (e) {
    return null;
  }
}

// Raw, unprocessed read of the state file: no migration, no synthesis, no
// convenience view. Callers that must distinguish "actually recorded on disk"
// from "readState() filled it in" (evaluateInheritance S3, #1681) need this.
// Fail-open: missing or corrupt file → null.
function readRawState(sessionId) {
  try {
    const raw = fs.readFileSync(getStatePath(sessionId), "utf8");
    return JSON.parse(raw);
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
  require("./completion-approval").applyCompletionBoundaryInvariant(sessionId, state, opts);
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
    const { isBugfixBranch } = require("./is-bugfix-session");
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
  state.steps[stepName] = { status, updated_at: new Date().toISOString(), ...extraFields };
  writeState(sessionId, state, opts);
}

// recordComplexityEvaluation(sessionId, level, signals):
// Top-level field writer (does NOT go through markStep). Read-modify-write.
// Write path — no fail-open: an invalid level throws.
function recordComplexityEvaluation(sessionId, level, signals) {
  let state = readState(sessionId);
  if (!state) {
    state = createInitialState(sessionId);
  }
  if (level !== "high" && level !== "low") {
    throw new Error(`recordComplexityEvaluation: level must be "high" or "low", got ${JSON.stringify(level)}`);
  }
  state.complexity_evaluation = {
    recorded_at: new Date().toISOString(),
    level,
    signals: Array.isArray(signals) ? signals : [],
  };
  writeState(sessionId, state);
}

// recordSessionModel(sessionId, { modelId | id, source }):
// Top-level field writer (like recordComplexityEvaluation). Read-modify-write.
// Freezes the session's model identity ONCE — re-invocation must not overwrite
// an already-recorded identity — and decides `verbose_prompt` in the same transaction so the
// flag and the identity can never disagree.
// The identifier key is accepted as `modelId` or `id`: resolveModelId() returns
// the `{ id, source }` shape and is passed straight through by SessionStart.
// Returns { recorded, verbosePrompt }. Write errors propagate to the caller,
// which is responsible for failing open.
function recordSessionModel(sessionId, descriptor) {
  const d = descriptor && typeof descriptor === "object" ? descriptor : {};
  const rawId = typeof d.modelId === "string" && d.modelId.trim() ? d.modelId : d.id;
  const modelId = typeof rawId === "string" && rawId.trim() ? rawId.trim() : null;
  if (!modelId) return { recorded: false, verbosePrompt: false };

  let state = readState(sessionId);
  if (!state) {
    state = createInitialState(sessionId);
  }
  // Write-once: must not turn into last-writer-wins.
  if (state.session_model) {
    return { recorded: false, verbosePrompt: state.verbose_prompt === true };
  }

  let verbosePrompt = false;
  try {
    require("../load-env").loadDefaultEnv();
    const { matchKeyword, parseKeywordList } = require("../model-match");
    verbosePrompt =
      matchKeyword(modelId, parseKeywordList(process.env.VERBOSE_PROMPT_MODELS)) !== null;
  } catch (_) {
    verbosePrompt = false;
  }

  state.session_model = {
    id: modelId,
    source: typeof d.source === "string" && d.source ? d.source : "unknown",
    recorded_at: new Date().toISOString(),
  };
  state.verbose_prompt = verbosePrompt;
  // readState adds skip_judgment as a convenience view only; writing it back
  // would persist it permanently.
  delete state.skip_judgment;
  writeState(sessionId, state);
  return { recorded: true, verbosePrompt };
}

// record the staged-tests fingerprint at sentinel-emission time
function markReviewTestsComplete(sessionId, token, extraFields = {}) {
  if (typeof token !== "string" || token.length === 0) {
    throw new Error("markReviewTestsComplete: token must be a non-empty string");
  }
  const { resolveWorkflowSessionId } = require("../resolve-workflow-session-id");
  let wsid = null;
  try { wsid = resolveWorkflowSessionId() || null; } catch (_) {}
  markStep(sessionId, "review_tests", "complete", { token, ...extraFields, wsid });
}

// Clear review_tests warnings while preserving the existing token/wsid.
// This is the state mutation for WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED.
// markStep does a full replace (no merge), so we must explicitly carry forward
// the existing token and wsid to avoid stale-token blocks in the gate.
function clearReviewTestsWarnings(sessionId, reason) {
  assertValidSessionId(sessionId); // explicit guard: readState's try-catch swallows errors
  const state = readState(sessionId);
  if (!state) return; // fail-open: nothing to clear
  const existing = (state.steps && state.steps.review_tests) || {};
  if (!existing.warnings_summary) return; // nothing to clear
  const token = existing.token || null;
  const wsid = existing.wsid || null;
  markStep(sessionId, "review_tests", "complete", {
    token,
    wsid,
    warnings_summary: null,
    warnings_accepted_reason: reason || null,
  });
}

// Remove the review-loop terminal marker written by run-codex-review-loop.sh
// after a non-success terminal exit (issue #1361). Accepting the coverage gap
// ends the review, so the re-invoke guard must no longer fire. Fail-open.
function clearReviewTestsTerminalMarker(sessionId) {
  try {
    assertValidSessionId(sessionId);
    const { getWorkflowPlansDir } = require("../workflow-plans-dir");
    const markerPath = path.join(
      getWorkflowPlansDir(),
      `${sessionId}-test-review-terminal.txt`
    );
    fs.unlinkSync(markerPath);
  } catch (e) {
    // ENOENT (no marker) and any other failure are non-fatal.
  }
}

// re-pending the review_tests step; clears the recorded token
function invalidateReviewTests(sessionId, reason) {
  markStep(sessionId, "review_tests", "pending", {
    token: null,
    invalidate_reason: reason || null,
  });
}

function cleanupZombies(maxAgeDays = 7) {
  const workflowDir = getWorkflowDir();
  let files;
  try {
    files = fs.readdirSync(workflowDir);
  } catch (e) {
    return;
  }

  const cutoff = Date.now() - maxAgeDays * 24 * 60 * 60 * 1000;
  const tmpCutoff = Date.now() - 24 * 60 * 60 * 1000;

  for (const file of files) {
    const filePath = path.join(workflowDir, file);

    // Catches every transient write-then-rename leftover on the 24h cutoff,
    // including the token-minting forms `<sid>.off-clearance.tmp` and
    // `<sid>.off-clearance.mint.tmp`. Runs before the marker-suffix set below.
    if (file.endsWith(".tmp")) {
      try {
        const st = fs.statSync(filePath);
        if (st.mtimeMs < tmpCutoff) fs.unlinkSync(filePath);
      } catch (e) {}
      continue;
    }

    if (
      file.endsWith(".workflow-off") ||
      file.endsWith(".worktree-off") ||
      file.endsWith(".issue-close-verified") ||
      file.endsWith(".next-step-paused") ||
      file.endsWith(".off-clearance")
    ) {
      try {
        const st = fs.statSync(filePath);
        if (st.mtimeMs < cutoff) fs.unlinkSync(filePath);
      } catch (e) {}
      continue;
    }

    if (!file.endsWith(".json")) continue;

    try {
      const raw = fs.readFileSync(filePath, "utf8");
      const state = JSON.parse(raw);

      const timestamps = [state.created_at]
        .concat(
          Object.values(state.steps || {}).map((s) => s && s.updated_at)
        )
        .filter(Boolean)
        .map((t) => new Date(t).getTime())
        .filter((t) => !isNaN(t));

      const maxTimestamp =
        timestamps.length > 0 ? Math.max(...timestamps) : 0;
      if (maxTimestamp < cutoff) {
        fs.unlinkSync(filePath);
      }
    } catch (e) {
      // unreadable or corrupt — skip
    }
  }
}


function setLastPushedSha(sessionId, sha) {
  const state = readState(sessionId);
  if (!state) return false;
  state.last_pushed_sha = sha;
  writeState(sessionId, state);
  return true;
}

function clearLastPushedSha(sessionId) {
  const state = readState(sessionId);
  if (!state) return false;
  state.last_pushed_sha = null;
  writeState(sessionId, state);
  return true;
}

function recordSessionWorktree(sessionId, worktreePath) {
  const state = readState(sessionId);
  if (!state) return;
  state.session_worktree = worktreePath;
  writeState(sessionId, state);
}

// Returns the effective skippable steps for the given session.
// BUGFIX sessions exclude write_tests and review_tests (T0-A gate).
// Lazy require avoids circular dependency with is-bugfix-session.js.
function getSkippableSteps(sessionId) {
  try {
    const { isBugfixSession } = require("./is-bugfix-session");
    if (isBugfixSession({ sessionId })) {
      return SKIPPABLE_STEPS.filter(s => s !== "write_tests" && s !== "review_tests");
    }
  } catch (_) {}
  return SKIPPABLE_STEPS;
}

// A-4 speculative-skip verdict lifecycle now lives in ./skip-verdict.js
// (aggregated by the workflow-state barrel).

module.exports = {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  VALID_STATUSES,
  getWorkflowDir,
  getStatePath,
  assertValidSessionId,
  SESSION_ID_VALID_RE,
  readState,
  readRawState,
  writeState,
  createInitialState,
  getCurrentContext,
  markStep,
  recordComplexityEvaluation,
  recordSessionModel,
  markReviewTestsComplete,
  clearReviewTestsWarnings,
  clearReviewTestsTerminalMarker,
  invalidateReviewTests,
  cleanupZombies,
  setLastPushedSha,
  clearLastPushedSha,
  getSkippableSteps,
  recordSessionWorktree,
};
