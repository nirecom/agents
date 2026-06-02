"use strict";

const { spawnSync } = require("child_process");

function isEnforceWorktreeOn() {
  let raw = process.env.ENFORCE_WORKTREE;
  if (raw === undefined || raw === null) {
    const legacy = process.env.AGENT_AUTO_BRANCH;
    if (legacy !== undefined && legacy !== null) {
      process.stderr.write(
        "enforce-worktree: AGENT_AUTO_BRANCH is deprecated; rename to ENFORCE_WORKTREE in agents config.\n"
      );
      raw = legacy;
    }
  }
  // No trim — whitespace-padded values are unknown and default ON (fail-safe block)
  const v = (raw || "").toLowerCase();
  // Default ON — only OFF when explicitly set to a recognised falsy value
  return !["off", "0", "false", "no", "disabled"].includes(v);
}

function getProtectedBranches(repoCwd) {
  // Prefer DEFAULT_BRANCHES; fall back to AGENT_DEFAULT_BRANCHES for migration.
  let override = (process.env.DEFAULT_BRANCHES || "").trim();
  if (!override && process.env.AGENT_DEFAULT_BRANCHES) {
    process.stderr.write(
      "enforce-worktree: AGENT_DEFAULT_BRANCHES is deprecated; rename to DEFAULT_BRANCHES in agents config.\n"
    );
    override = (process.env.AGENT_DEFAULT_BRANCHES || "").trim();
  }
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

module.exports = { isEnforceWorktreeOn, getProtectedBranches, getCurrentBranch };
