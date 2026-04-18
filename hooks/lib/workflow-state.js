#!/usr/bin/env node
// Shared state module for workflow hooks

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");

/**
 * Resolve the current session ID from CLAUDE_ENV_FILE.
 * CLAUDE_ENV_FILE is set by Claude Code in hook contexts (SessionStart, PreToolUse, etc.)
 * and contains KEY=VALUE lines written by session-start.js.
 * Returns null if CLAUDE_ENV_FILE is not set or CLAUDE_SESSION_ID is not found.
 */
function resolveSessionId() {
  const envFile = process.env.CLAUDE_ENV_FILE;
  if (!envFile) return null;
  try {
    const content = fs.readFileSync(envFile, "utf8");
    const match = content.match(/^CLAUDE_SESSION_ID=(.+)$/m);
    return match ? match[1].trim() : null;
  } catch (e) {
    return null;
  }
}

const VALID_STEPS = [
  "research",
  "plan",
  "write_tests",
  "code",
  "verify",
  "docs",
  "user_verification",
];
const SKIPPABLE_STEPS = ["research", "plan"];
const VALID_STATUSES = ["pending", "in_progress", "complete", "skipped"];

// State is stored in ~/.claude/projects/workflow/{session-id}.json (session-scoped).
// CLAUDE_WORKFLOW_DIR env var overrides the directory (used in tests).
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
    return JSON.parse(raw);
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
    files = fs
      .readdirSync(transcriptDir)
      .filter((f) => f.endsWith(".jsonl"))
      .map((f) => ({
        name: f,
        mtime: fs.statSync(path.join(transcriptDir, f)).mtimeMs,
      }))
      .sort((a, b) => b.mtime - a.mtime)
      .slice(0, 10);
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
  // NOTE: extraFields are spread in — calling without extraFields clears previous
  // extras (e.g. skip_reason). Intentional: overwrite semantics match idempotency.
  state.steps[stepName] = { status, updated_at: new Date().toISOString(), ...extraFields };
  writeState(sessionId, state);
}

function cleanupZombies(maxAgeDays = 7) {
  const workflowDir = getWorkflowDir();
  let files;
  try {
    files = fs.readdirSync(workflowDir);
  } catch (e) {
    return; // Directory doesn't exist — skip cleanup
  }

  const cutoff = Date.now() - maxAgeDays * 24 * 60 * 60 * 1000;
  const tmpCutoff = Date.now() - 24 * 60 * 60 * 1000;

  for (const file of files) {
    const filePath = path.join(workflowDir, file);

    // Clean up stale .tmp files (crash leftovers) older than 24h
    if (file.endsWith(".tmp")) {
      try {
        const st = fs.statSync(filePath);
        if (st.mtimeMs < tmpCutoff) fs.unlinkSync(filePath);
      } catch (e) {}
      continue;
    }

    if (!file.endsWith(".json")) continue;

    try {
      const raw = fs.readFileSync(filePath, "utf8");
      const state = JSON.parse(raw);

      // Collect all timestamps from steps and created_at
      const timestamps = [state.created_at]
        .concat(
          Object.values(state.steps || {}).map((s) => s && s.updated_at)
        )
        .filter(Boolean)
        .map((t) => new Date(t).getTime())
        .filter((t) => !isNaN(t));

      // If all timestamps are older than cutoff (or no valid timestamps), delete
      const maxTimestamp =
        timestamps.length > 0 ? Math.max(...timestamps) : 0;
      if (maxTimestamp < cutoff) {
        fs.unlinkSync(filePath);
      }
    } catch (e) {
      // Unreadable or corrupt file — skip
    }
  }
}

module.exports = {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  VALID_STATUSES,
  resolveSessionId,
  readState,
  writeState,
  markStep,
  createInitialState,
  cleanupZombies,
  getWorkflowDir,
  getCurrentContext,
  findLatestStateForContext,
};
