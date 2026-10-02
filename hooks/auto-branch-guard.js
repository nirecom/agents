#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce AGENT_AUTO_BRANCH policy — block
// Edit/Write/MultiEdit when AGENT_AUTO_BRANCH is on (default) and the target file's
// repo is on its default branch (main/master), so feature branches are structural.
// Allowed: AGENT_AUTO_BRANCH=off|0|false|no|disabled, file outside any git repo,
// unborn or detached HEAD, any non-default branch. Unreadable stdin blocks.

const fs = require("fs");
const { spawnSync } = require("child_process");
const path = require("path");

// Load $AGENTS_CONFIG_DIR/.env into process.env (existing env wins)
try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { normalizeCwd } = require("./lib/path-normalize");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "auto-branch-guard";

function isAutoBranchOn() {
  const v = (process.env.AGENT_AUTO_BRANCH || "").toLowerCase().trim();
  // Default ON — only OFF when explicitly set to a falsy value
  return !["off", "0", "false", "no", "disabled"].includes(v);
}

function getProtectedBranches(repoCwd) {
  // Override env var: comma-separated list overrides default-branch detection.
  // Example: AGENT_DEFAULT_BRANCHES=develop,trunk,main
  const override = (process.env.AGENT_DEFAULT_BRANCHES || "").trim();
  if (override) {
    return override.split(",").map((s) => s.trim()).filter(Boolean);
  }

  const branches = new Set();
  // 1. origin/HEAD (most authoritative when origin exists)
  try {
    const r = spawnSync("git", ["symbolic-ref", "refs/remotes/origin/HEAD"], {
      cwd: repoCwd,
      encoding: "utf8",
      timeout: 2000,
    });
    if (r.status === 0) {
      const m = (r.stdout || "").trim().match(/refs\/remotes\/origin\/(.+)$/);
      if (m) branches.add(m[1]);
    }
  } catch (e) {}

  // 2. local refs/heads/main and refs/heads/master (well-known)
  for (const candidate of ["main", "master"]) {
    try {
      const r = spawnSync("git", ["show-ref", "--verify", "--quiet", `refs/heads/${candidate}`], {
        cwd: repoCwd,
        timeout: 2000,
      });
      if (r.status === 0) branches.add(candidate);
    } catch (e) {}
  }

  // 3. init.defaultBranch
  try {
    const r = spawnSync("git", ["config", "init.defaultBranch"], {
      cwd: repoCwd,
      encoding: "utf8",
      timeout: 2000,
    });
    if (r.status === 0) {
      const v = (r.stdout || "").trim();
      if (v) branches.add(v);
    }
  } catch (e) {}

  // 4. fallback
  if (branches.size === 0) branches.add("main");

  return [...branches];
}

function getCurrentBranch(repoCwd) {
  // Returns null if detached HEAD or unborn HEAD (no commits yet)
  try {
    // First: check HEAD has commits. Unborn HEAD → branching is meaningless → allow.
    const verify = spawnSync("git", ["rev-parse", "--verify", "HEAD"], {
      cwd: repoCwd,
      timeout: 2000,
    });
    if (verify.status !== 0) return null; // unborn HEAD

    const r = spawnSync("git", ["symbolic-ref", "--short", "HEAD"], {
      cwd: repoCwd,
      encoding: "utf8",
      timeout: 2000,
    });
    if (r.status !== 0) return null; // detached HEAD
    return (r.stdout || "").trim() || null;
  } catch (e) {
    return null;
  }
}

function findRepoRoot(filePath) {
  // From the file's directory, walk up via git rev-parse --show-toplevel.
  // Normalize POSIX drive-letter paths to Windows form on Windows for path.resolve safety.
  let dir;
  try {
    const normalized = normalizeCwd(filePath) || filePath;
    dir = path.dirname(path.resolve(normalized));
  } catch (e) {
    return null;
  }
  try {
    const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: dir,
      encoding: "utf8",
      timeout: 2000,
    });
    if (r.status !== 0) return null;
    const root = (r.stdout || "").trim();
    return root || null;
  } catch (e) {
    return null;
  }
}

function done(decision) {
  if (decision && decision.block) {
    console.log(JSON.stringify({ decision: "block", reason: decision.reason }));
  } else {
    console.log(JSON.stringify({}));
  }
  process.exit(0);
}

// Main
const r = readHookInput();
if (r.kind === "read-error") done({ block: true, reason: readFailureReason(HOOK_NAME, r.error) });
if (r.kind === "json-invalid") {
  try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
  done(); // fail-open on malformed stdin
}
const input = r.input;

if (!isAutoBranchOn()) done();

const toolName = input.tool_name;
if (!["Edit", "Write", "MultiEdit"].includes(toolName)) done();

const filePath = input.tool_input && input.tool_input.file_path;
if (!filePath || typeof filePath !== "string") done();

const repoRoot = findRepoRoot(filePath);
if (!repoRoot) done(); // not in a git repo

const currentBranch = getCurrentBranch(repoRoot);
if (!currentBranch) done(); // detached HEAD or unborn

const protectedBranches = getProtectedBranches(repoRoot);
if (!protectedBranches.includes(currentBranch)) done(); // on a feature branch

// On default branch with AUTO_BRANCH on — block
const reason =
  `AUTO_BRANCH: edits to default branch '${currentBranch}' are blocked.\n` +
  `Run: git switch -c <feature-name>\n` +
  `Or set AGENT_AUTO_BRANCH=off in .env to disable.`;
done({ block: true, reason });
