#!/usr/bin/env node
// Shared state module for workflow hooks

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

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

function getWorkflowDir(repoDir) {
  const gitDir = execSync("git rev-parse --git-dir", {
    cwd: repoDir,
    encoding: "utf8",
    timeout: 5000,
    stdio: ["pipe", "pipe", "pipe"],
  }).trim();
  const absGitDir = path.isAbsolute(gitDir)
    ? gitDir
    : path.join(repoDir, gitDir);
  return path.join(absGitDir, "workflow");
}

function getStatePath(repoDir, sessionId) {
  return path.join(getWorkflowDir(repoDir), sessionId + ".json");
}

function readState(repoDir, sessionId) {
  try {
    const filePath = getStatePath(repoDir, sessionId);
    const raw = fs.readFileSync(filePath, "utf8");
    return JSON.parse(raw);
  } catch (e) {
    return null;
  }
}

function writeState(repoDir, sessionId, state) {
  const workflowDir = getWorkflowDir(repoDir);
  fs.mkdirSync(workflowDir, { recursive: true });
  const filePath = getStatePath(repoDir, sessionId);
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, JSON.stringify(state, null, 2), "utf8");
  fs.renameSync(tmpPath, filePath);
}

function createInitialState(sessionId) {
  const steps = {};
  for (const step of VALID_STEPS) {
    steps[step] = { status: "pending", updated_at: null };
  }
  return {
    version: 1,
    session_id: sessionId,
    created_at: new Date().toISOString(),
    steps,
  };
}

function markStep(repoDir, sessionId, stepName, status) {
  let state = readState(repoDir, sessionId);
  if (!state) {
    state = createInitialState(sessionId);
  }
  state.steps[stepName] = { status, updated_at: new Date().toISOString() };
  writeState(repoDir, sessionId, state);
}

function cleanupZombies(repoDir, maxAgeDays = 7) {
  let workflowDir;
  try {
    workflowDir = getWorkflowDir(repoDir);
  } catch (e) {
    return; // No git repo or other error — skip cleanup
  }

  let files;
  try {
    files = fs.readdirSync(workflowDir).filter((f) => f.endsWith(".json"));
  } catch (e) {
    return; // Directory doesn't exist — skip cleanup
  }

  const cutoff = Date.now() - maxAgeDays * 24 * 60 * 60 * 1000;

  for (const file of files) {
    const filePath = path.join(workflowDir, file);
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
  readState,
  writeState,
  markStep,
  createInitialState,
  cleanupZombies,
};
