"use strict";

const { spawnSync } = require("child_process");
const path = require("path");
const { parseGitCPath, findRepoRoot } = require("./git-repo-detection");
const { isCoveredByEntryList } = require("../lib/path-coverage-match");

const _warnedDeprecated = new Set();

function isEnforceWorktreeOn() {
  const raw = process.env.ENFORCE_WORKTREE;
  // No trim — whitespace-padded values are unknown and default ON (fail-safe block)
  const v = (raw || "").toLowerCase();
  // Default ON — only OFF when explicitly set to a recognised falsy value
  return !["off", "0", "false", "no", "disabled"].includes(v);
}

function getProtectedBranches(repoCwd) {
  const override = (process.env.DEFAULT_BRANCHES || "").trim();
  if (override) {
    return override.split(",").map((s) => s.trim()).filter(Boolean);
  }

  const branches = new Set();
  try {
    const r = spawnSync("git", ["symbolic-ref", "refs/remotes/origin/HEAD"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    if (r.status === 0) {
      const m = (r.stdout || "").trim().match(/refs\/remotes\/origin\/(.+)$/);
      if (m) branches.add(m[1]);
    }
  } catch (e) {}
  for (const c of ["main", "master"]) {
    try {
      const r = spawnSync("git", ["show-ref", "--verify", "--quiet", `refs/heads/${c}`], {
        cwd: repoCwd, timeout: 2000,
      });
      if (r.status === 0) branches.add(c);
    } catch (e) {}
  }
  try {
    const r = spawnSync("git", ["config", "init.defaultBranch"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    if (r.status === 0) { const v = (r.stdout || "").trim(); if (v) branches.add(v); }
  } catch (e) {}
  if (branches.size === 0) branches.add("main");
  return [...branches];
}

function getCurrentBranch(repoCwd) {
  try {
    const verify = spawnSync("git", ["rev-parse", "--verify", "HEAD"], { cwd: repoCwd, timeout: 2000 });
    if (verify.status !== 0) return null; // unborn HEAD
    const r = spawnSync("git", ["symbolic-ref", "--short", "HEAD"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null; // detached HEAD
    return (r.stdout || "").trim() || null;
  } catch (e) {
    return null;
  }
}

// Check if a repo directory is excluded from worktree enforcement.
// Reads the unified ENFORCE_WORKTREE_EXCLUDE (path-coverage). A plain path entry
// covers that repo root and its subtree; glob entries match file paths.
// ENFORCE_WORKTREE_EXCLUDE_REPOS is a deprecated alias, merged in once per process.
function isRepoExcluded(repoDir) {
  // --- BEGIN temporary: ENFORCE_WORKTREE_EXCLUDE_REPOS → ENFORCE_WORKTREE_EXCLUDE migration ---
  if (process.env.ENFORCE_WORKTREE_EXCLUDE_REPOS && !process.env._EXCL_REPOS_MIGRATED) {
    if (!_warnedDeprecated.has("ENFORCE_WORKTREE_EXCLUDE_REPOS")) {
      process.stderr.write(
        "enforce-worktree: ENFORCE_WORKTREE_EXCLUDE_REPOS is deprecated; " +
        "migrate entries to ENFORCE_WORKTREE_EXCLUDE in your .env\n"
      );
      _warnedDeprecated.add("ENFORCE_WORKTREE_EXCLUDE_REPOS");
    }
    const existing = process.env.ENFORCE_WORKTREE_EXCLUDE || "";
    const extra = process.env.ENFORCE_WORKTREE_EXCLUDE_REPOS;
    process.env.ENFORCE_WORKTREE_EXCLUDE = existing ? existing + ";" + extra : extra;
    process.env._EXCL_REPOS_MIGRATED = "1";
  }
  // --- END temporary: ENFORCE_WORKTREE_EXCLUDE_REPOS → ENFORCE_WORKTREE_EXCLUDE migration ---
  const resolved = path.resolve(repoDir);
  return isCoveredByEntryList(process.env.ENFORCE_WORKTREE_EXCLUDE || "", resolved);
}

// Check whether the repo implied by a tool input (via git -C path or CWD) is excluded.
// Returns true if excluded, false otherwise.
function isCommandRepoExcluded(input, cwd) {
  const cmd = (input && input.tool_input && input.tool_input.command) || "";
  const cPath = cmd ? parseGitCPath(cmd) : null;
  const repoRoot = cPath ? cPath : findRepoRoot(cwd);
  return !!(repoRoot && isRepoExcluded(repoRoot));
}

module.exports = { isEnforceWorktreeOn, getProtectedBranches, getCurrentBranch, isRepoExcluded, isCommandRepoExcluded };
