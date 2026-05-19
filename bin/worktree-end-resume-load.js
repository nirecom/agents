#!/usr/bin/env node
/**
 * bin/worktree-end-resume-load.js
 *
 * Resumes a deferred /worktree-end cleanup after a Windows EPERM failure.
 * Invoked by `skills/worktree-end/SKILL.md` step 1 when --resume flag is present.
 *
 * Usage:
 *   node bin/worktree-end-resume-load.js --plans-dir <path>
 *
 * Reads the pending-cwd-unlock- marker written by SKILL.md step 6.b.6, then
 * replays steps 6c–6h: worktree remove, prune, orphan-dir cleanup, branch -D,
 * and marker cleanup.
 *
 * Exit codes:
 *   0  — no marker found (no-op), or cleanup completed successfully
 *   1  — invalid/malformed marker, path traversal, or cleanup failure
 */

"use strict";

const fs   = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { getRepoId, getMarkerPath, getWorktreeBaseDir, MARKER_PREFIXES } =
  require("../hooks/enforce-worktree.js");

// ─── CLI parsing ─────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
let plansDir = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--plans-dir" && args[i + 1]) { plansDir = args[++i]; }
}

if (!plansDir) {
  // Fall back to WORKFLOW_PLANS_DIR env var if --plans-dir not passed
  plansDir = process.env.WORKFLOW_PLANS_DIR || path.join(require("os").homedir(), ".workflow-plans");
}

// ─── Repo-id resolution ───────────────────────────────────────────────────────

const repoRoot = process.cwd();
const repoId = getRepoId(repoRoot);
if (!repoId) {
  console.error("ERROR: Cannot resolve repo-id from cwd: " + repoRoot);
  console.error("Run from the main worktree of the target repository.");
  process.exit(1);
}

const baseDir = getWorktreeBaseDir();
// getWorktreeBaseDir() always returns a non-null absolute path in practice.
if (!baseDir) {
  console.error("ERROR: Cannot resolve WORKTREE_BASE_DIR.");
  process.exit(1);
}

// ─── Marker discovery ─────────────────────────────────────────────────────────

const worktreeEndDir = path.join(plansDir, "worktree-end");
const prefix = MARKER_PREFIXES.CWD_UNLOCK + repoId + "--";

let candidates = [];
try {
  const entries = fs.readdirSync(worktreeEndDir);
  const prefixLower = process.platform === "win32" ? prefix.toLowerCase() : prefix;
  candidates = entries.filter((e) => {
    const en = process.platform === "win32" ? e.toLowerCase() : e;
    return en.startsWith(prefixLower);
  }).map((e) => path.join(worktreeEndDir, e));
} catch (e) {
  if (e.code === "ENOENT") {
    // No worktree-end dir means no marker — exit 0 (no-op)
    process.exit(0);
  }
  console.error("ERROR: Cannot read worktree-end directory: " + e.message);
  process.exit(1);
}

if (candidates.length === 0) {
  // No pending-cwd-unlock marker — nothing to resume
  process.exit(0);
}

if (candidates.length > 1) {
  console.error("ERROR: Multiple pending-cwd-unlock markers found for this repo:");
  candidates.forEach((c) => console.error("  " + c));
  console.error("Manual cleanup required. Delete stale markers and re-run.");
  process.exit(1);
}

const markerPath = candidates[0];

// ─── Marker validation ────────────────────────────────────────────────────────

let content;
try { content = fs.readFileSync(markerPath, "utf8"); }
catch (e) {
  if (e.code === "ENOENT") process.exit(0); // race: marker just deleted
  console.error("ERROR: Cannot read marker file: " + e.message);
  process.exit(1);
}

const lines = content.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);

if (lines.length < 3) {
  console.error("ERROR: Marker file is malformed: " + markerPath);
  console.error("Expected 3 lines: <branch> / <worktree-path> / pre-remove");
  console.error("Manual cleanup required. Delete the marker and re-run /worktree-end.");
  process.exit(1);
}

const branch       = lines[0];
const worktreePath = lines[1];
const stage        = lines[2];

if (!branch) {
  console.error("ERROR: Marker file is malformed: " + markerPath);
  console.error("Expected 3 lines: <branch> / <worktree-path> / pre-remove");
  console.error("Manual cleanup required. Delete the marker and re-run /worktree-end.");
  process.exit(1);
}

const KNOWN_STAGES = new Set(["pre-remove"]);

if (!KNOWN_STAGES.has(stage)) {
  console.error("ERROR: Unknown resume stage in marker: " + markerPath);
  console.error('Stage: "' + stage + '" is not supported by this version.');
  process.exit(1);
}

// Validate worktree path is under WORKTREE_BASE_DIR (security: path traversal guard)
const norm = (p) => {
  try {
    const r = path.resolve(p);
    return process.platform === "win32" ? r.toLowerCase() : r;
  } catch (e) { return null; }
};
const nBase   = norm(baseDir);
const nWtree  = norm(worktreePath);
if (!nBase || !nWtree) {
  console.error("ERROR: Cannot normalize paths for validation.");
  process.exit(1);
}
const underBase = nWtree === nBase ||
                  nWtree.startsWith(nBase + path.sep) ||
                  nWtree.startsWith(nBase + "/");
if (!underBase) {
  console.error("ERROR: Worktree path is outside WORKTREE_BASE_DIR: " + worktreePath);
  console.error("WORKTREE_BASE_DIR: " + baseDir);
  console.error("Manual cleanup required.");
  process.exit(1);
}

// ─── Resume action (stage=pre-remove) ─────────────────────────────────────────

console.log("Resuming deferred /worktree-end cleanup...");
console.log("  Branch:   " + branch);
console.log("  Worktree: " + worktreePath);

const agentsDir = path.resolve(__dirname, "..");

function run(cmd, args, opts) {
  const r = spawnSync(cmd, args, { encoding: "utf8", timeout: 30000, ...opts });
  return r;
}

// Step 1: git worktree remove
console.log("\n[6c] git worktree remove " + worktreePath);
const removeResult = run("git", ["-C", repoRoot, "worktree", "remove", worktreePath]);
let alreadyGone = false;
if (removeResult.status !== 0) {
  const stderr = (removeResult.stderr || "").toLowerCase();
  if (stderr.includes("not a working tree") || stderr.includes("is not a working tree")) {
    console.log("  Worktree already removed — continuing with branch/marker cleanup.");
    alreadyGone = true;
  } else {
    console.error("ERROR: git worktree remove failed:");
    console.error(removeResult.stderr || "(no stderr)");
    process.exit(1);
  }
}

if (!alreadyGone) {
  // Step 2: git worktree prune
  console.log("\n[6d] git worktree prune");
  run("git", ["-C", repoRoot, "worktree", "prune"]);

  // Step 3: cleanup-orphan-dir
  console.log("\n[6e] cleanup-orphan-dir " + worktreePath + " --force-if-not-registered");
  const orphanScript = path.join(agentsDir, "hooks", "cleanup-orphan-dir.js");
  if (fs.existsSync(orphanScript)) {
    const orphanResult = run(process.execPath, [orphanScript, worktreePath, "--force-if-not-registered"]);
    if (orphanResult.status !== 0) {
      console.warn("WARN: cleanup-orphan-dir exited " + orphanResult.status + ": " + (orphanResult.stderr || ""));
    }
  }
}

// Step 4: git branch -D (authorised by existing pending-branch-delete- marker)
console.log("\n[6f] git branch -D " + branch);
const branchResult = run("git", ["-C", repoRoot, "branch", "-D", branch]);
if (branchResult.status !== 0) {
  const msg = (branchResult.stderr || "").toLowerCase();
  if (msg.includes("not found") || msg.includes("error: branch") || msg.includes("no branch named")) {
    console.log("  Branch already deleted — continuing.");
  } else {
    console.warn("WARN: git branch -D failed: " + (branchResult.stderr || ""));
  }
}

// Step 5: delete pending-branch-delete- marker (if it exists)
const bdMarkerPath = getMarkerPath(repoRoot, branch, MARKER_PREFIXES.BRANCH_DELETE);
if (bdMarkerPath) {
  console.log("\n[6g] Removing branch-delete marker");
  try {
    if (fs.existsSync(bdMarkerPath)) {
      fs.unlinkSync(bdMarkerPath);
      console.log("  Removed: " + bdMarkerPath);
    }
  } catch (e) {
    console.warn("WARN: Could not remove branch-delete marker: " + e.message);
  }
}

// Step 6: delete pending-cwd-unlock- marker
console.log("\n[6g.1] Removing cwd-unlock marker");
try {
  fs.unlinkSync(markerPath);
  console.log("  Removed: " + markerPath);
} catch (e) {
  if (e.code !== "ENOENT") {
    console.warn("WARN: Could not remove cwd-unlock marker: " + e.message);
  }
}

// Step 7: git fetch --prune + pull --ff-only
console.log("\n[6h] git fetch --prune origin && pull --ff-only");
const fetchResult = run("git", ["-C", repoRoot, "fetch", "--prune", "origin"]);
if (fetchResult.status !== 0) {
  console.warn("WARN: git fetch --prune failed: " + (fetchResult.stderr || ""));
} else {
  const pullResult = run("git", ["-C", repoRoot, "pull", "--ff-only"]);
  if (pullResult.status !== 0) {
    console.warn("WARN: git pull --ff-only failed: " + (pullResult.stderr || ""));
  }
}

console.log("\nDeferred cleanup complete.");
