// hooks/enforce-worktree/effective-target/natural-git.js
// #3147: a directory's git identity with every target-redirecting variable stripped, so an
// inherited GIT_DIR / GIT_WORK_TREE cannot make the session anchors describe another repo.

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("../../lib/limited-child-process");
const { toWindowsPath } = require("../../lib/branch-diff");
const { normalizeForCompare } = require("../git-repo-detection");
const { getNarrowedSessionRoots } = require("../session-scope");

const IDENTITY_ENV = ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_CONFIG_PARAMETERS"];

function strippedEnv() {
  const env = { ...process.env };
  for (const k of IDENTITY_ENV) delete env[k];
  return env;
}

function gitLines(args, dir) {
  try {
    const r = spawnSync("git", args, { cwd: toWindowsPath(dir), env: strippedEnv(), encoding: "utf8", timeout: 2000 });
    if (r.error || r.status !== 0) return null;
    return (r.stdout || "").trim().split(/\r?\n/);
  } catch {
    return null;
  }
}

// A git dir spelled through a junction, symlink or 8.3 name compares equal to its real path.
function canonDir(p) {
  try {
    return normalizeForCompare(fs.realpathSync.native(p));
  } catch {
    return normalizeForCompare(p);
  }
}

// → { root, gitDir, commonDir, isMain } (normalizeForCompare form; gitDir / commonDir by real path) | null when not a work tree.
function naturalIdentity(dir) {
  if (!dir) return null;
  const lines = gitLines(["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"], dir);
  if (!lines || lines.length < 3 || lines.some((l) => !l)) return null;
  const base = toWindowsPath(dir);
  const [root] = lines.map((l) => normalizeForCompare(path.resolve(base, l)));
  const gitDir = canonDir(path.resolve(base, lines[1]));
  const commonDir = canonDir(path.resolve(base, lines[2]));
  return { root, gitDir, commonDir, isMain: gitDir === commonDir };
}

function naturalRoot(dir) {
  const id = naturalIdentity(dir);
  return id ? id.root : null;
}

function naturalBranch(root) {
  const lines = gitLines(["symbolic-ref", "--short", "HEAD"], root);
  return lines && lines[0] ? lines[0] : null;
}

// Common dirs and worktree paths of the session repos (cwd repo + narrowed roots);
// null when the cwd is not a repo or any listing fails (fail-closed).
function naturalAnchors(toolCwd) {
  const cwdId = naturalIdentity(toolCwd || process.cwd());
  if (!cwdId) return null;
  const roots = new Set(getNarrowedSessionRoots(naturalRoot));
  roots.add(cwdId.root);
  const commonDirs = new Set();
  const worktreePaths = new Set();
  for (const r of roots) {
    const id = naturalIdentity(r);
    const list = id ? gitLines(["worktree", "list", "--porcelain"], r) : null;
    if (!list) return null;
    commonDirs.add(id.commonDir);
    for (const line of list) {
      if (line.startsWith("worktree ")) worktreePaths.add(normalizeForCompare(line.slice("worktree ".length)));
    }
  }
  return { cwdId, commonDirs, worktreePaths: [...worktreePaths] };
}

module.exports = { IDENTITY_ENV, canonDir, naturalIdentity, naturalAnchors, naturalBranch };
