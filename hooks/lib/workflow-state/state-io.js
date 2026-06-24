"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");
const { _listJsonlByMtime } = require("./session-id");

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

function getStatePath(sessionId) {
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
    }
    return state;
  } catch (e) {
    return null;
  }
}

function writeState(sessionId, state) {
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
  }
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

const SESSION_ID_RE = /Current workflow session_id:\s*([^\s\\]+)/;

function findLatestStateForContext(ctx) {
  if (!ctx || typeof ctx.cwd !== "string") return null;

  const encoded = ctx.cwd.toLowerCase().replace(/[^a-zA-Z0-9]/g, "-");
  const transcriptBase = process.env.CLAUDE_TRANSCRIPT_BASE_DIR ||
    path.join(os.homedir(), ".claude", "projects");
  const transcriptDir = path.join(transcriptBase, encoded);

  let files;
  try {
    files = _listJsonlByMtime(transcriptDir).slice(0, 10);
  } catch (e) {
    return null;
  }

  for (const { name } of files) {
    const filePath = path.join(transcriptDir, name);
    const foundIds = [];
    try {
      const content = fs.readFileSync(filePath, "utf8");
      for (const line of content.split("\n")) {
        if (!line) continue;
        try {
          const entry = JSON.parse(line);
          if (entry.type !== "attachment") continue;
          const att = entry.attachment;
          if (!att || att.exitCode !== 0) continue;
          if (!["SessionStart", "PostCompact"].includes(att.hookEvent)) continue;
          const m = (att.stdout || "").match(SESSION_ID_RE);
          if (m) foundIds.push(m[1]);
        } catch (e) {}
      }
    } catch (e) { continue; }

    if (foundIds.length === 0) continue;

    for (const id of [...foundIds].reverse()) {
      try {
        const state = readState(id);
        if (!state) continue;
        if ((state.git_branch ?? null) !== (ctx.git_branch ?? null)) continue;
        const allPending = Object.values(state.steps || {})
          .every((v) => !v || v.status === "pending");
        if (allPending) continue;
        if (state.steps?.user_verification?.status === "complete") break;
        return state;
      } catch (e) { continue; }
    }
  }
  return null;
}

function markStep(sessionId, stepName, status, extraFields = {}) {
  let state = readState(sessionId);
  if (!state) {
    state = createInitialState(sessionId);
  }
  state.steps[stepName] = { status, updated_at: new Date().toISOString(), ...extraFields };
  writeState(sessionId, state);
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

    if (file.endsWith(".tmp")) {
      try {
        const st = fs.statSync(filePath);
        if (st.mtimeMs < tmpCutoff) fs.unlinkSync(filePath);
      } catch (e) {}
      continue;
    }

    if (file.endsWith(".workflow-off") || file.endsWith(".worktree-off") || file.endsWith(".issue-close-verified")) {
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

module.exports = {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  VALID_STATUSES,
  getWorkflowDir,
  getStatePath,
  readState,
  writeState,
  createInitialState,
  getCurrentContext,
  findLatestStateForContext,
  markStep,
  markReviewTestsComplete,
  invalidateReviewTests,
  cleanupZombies,
  setLastPushedSha,
  clearLastPushedSha,
};
