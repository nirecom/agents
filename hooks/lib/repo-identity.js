"use strict";
// Repo-identity verdicts: are two directories the same checkout, sibling
// worktrees of one repository, or different repositories? Owned here so hooks
// (workflow-gate, inheritance) and bin (next-step, resume-session) share one
// comparator without a hooks -> bin dependency.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("./limited-child-process");

const VERDICTS = Object.freeze({
  SAME: "same",
  SIBLING: "sibling-worktree",
  DIFFERENT: "different-repo",
  UNKNOWN: "unknown",
  INDETERMINATE: "indeterminate",
});

// Matches main-worktree.js GIT_REPO_ENV: env vars that redirect git's idea of which repo to use.
const GIT_REPO_ENV_NAMES = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"];

// Lexical form only: drive-letter spellings (`/C/x`, `c:/x`, `C:\x`), trailing
// separators and case differences are the same path, and samePath() in
// inheritance/context-match.js misses all three.
function normalizePathForCompare(value) {
  if (typeof value !== "string" || value.length === 0) return null;
  let out = value.trim();
  if (out.length === 0) return null;
  out = out.replace(/\\/g, "/");
  const posixDrive = /^\/([A-Za-z])\//.exec(out);
  if (posixDrive) out = posixDrive[1] + ":/" + out.slice(3);
  out = out.replace(/\/+$/, "");
  return out.toLowerCase();
}

function git(dir, args) {
  try {
    const env = Object.assign({}, process.env);
    for (const k of GIT_REPO_ENV_NAMES) delete env[k];
    const r = spawnSync("git", ["-C", dir].concat(args), {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "pipe"],
      env,
    });
    if (!r || r.error || r.status !== 0) return null;
    return String(r.stdout || "").trim();
  } catch (e) {
    return null;
  }
}

// { toplevel, commonDir } both normalized, or null. The caller passes a Windows
// path (toWindowsPath applied): POSIX drive-letter form reaches git() as ENOENT.
function resolveRepoLocation(dir) {
  if (typeof dir !== "string" || dir.length === 0) return null;
  const toplevelRaw = git(dir, ["rev-parse", "--show-toplevel"]);
  const commonDirRaw = git(dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  if (toplevelRaw === null || commonDirRaw === null) return null;
  return {
    toplevel: normalizePathForCompare(toplevelRaw),
    commonDir: normalizePathForCompare(commonDirRaw),
  };
}

function compareRepoIdentity(recordedCwd, repoDir) {
  const a = normalizePathForCompare(recordedCwd);
  const b = normalizePathForCompare(repoDir);
  if (a === null) return VERDICTS.UNKNOWN;
  if (b === null) return VERDICTS.UNKNOWN;
  if (a === b) return VERDICTS.SAME;

  const topA = git(recordedCwd, ["rev-parse", "--show-toplevel"]);
  const topB = git(repoDir, ["rev-parse", "--show-toplevel"]);
  if (topA === null || topB === null) return VERDICTS.INDETERMINATE;
  if (normalizePathForCompare(topA) === normalizePathForCompare(topB)) return VERDICTS.SAME;

  const commonA = git(recordedCwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  const commonB = git(repoDir, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  if (commonA === null || commonB === null) return VERDICTS.INDETERMINATE;
  if (normalizePathForCompare(commonA) === normalizePathForCompare(commonB)) return VERDICTS.SIBLING;
  return VERDICTS.DIFFERENT;
}

// Two-valued on purpose: "cannot tell" is not equivalence, so a spawn failure
// lands on false rather than inventing a third outcome.
function compareRepoContentEquivalence(dirA, dirB) {
  const headA = git(dirA, ["rev-parse", "HEAD"]);
  const headB = git(dirB, ["rev-parse", "HEAD"]);
  if (headA === null || headB === null) return false;
  // HEAD equality is the floor for EVERY branch, dirty or clean: two trees on
  // divergent commits carrying the same uncommitted diff are not equivalent.
  if (headA !== headB) return false;
  const statusA = git(dirA, ["status", "--porcelain"]);
  const statusB = git(dirB, ["status", "--porcelain"]);
  if (statusA === null || statusB === null) return false;
  if (statusA.length === 0 && statusB.length === 0) return true;
  // A dirty tree is what the session actually holds, so on a shared HEAD the
  // working-tree diff is the remaining fact that decides equivalence.
  const diffA = git(dirA, ["diff", "HEAD"]);
  const diffB = git(dirB, ["diff", "HEAD"]);
  if (diffA === null || diffB === null) return false;
  if (diffA !== diffB) return false;
  // `git diff HEAD` is blind to untracked files, so a tracked-diff match alone
  // would call two trees equivalent while one carries files the other lacks.
  return untrackedContentMatches(dirA, dirB);
}

function untrackedPaths(dir) {
  const out = git(dir, ["ls-files", "--others", "--exclude-standard"]);
  if (out === null) return null;
  return out.split(/\r?\n/).filter((p) => p.length > 0).sort();
}

const MAX_UNTRACKED_COMPARE_BYTES = 1024 * 1024;

// lstat, never stat: a symlink is compared as a link, so following it into an
// arbitrary target can never make two trees look equivalent. The size cap keeps
// an untracked multi-gigabyte blob from being read into memory to prove it.
function untrackedFileEquals(fileA, fileB) {
  const statA = fs.lstatSync(fileA);
  const statB = fs.lstatSync(fileB);
  if (!statA.isFile() || !statB.isFile()) return false;
  if (statA.size !== statB.size) return false;
  if (statA.size > MAX_UNTRACKED_COMPARE_BYTES) return false;
  return fs.readFileSync(fileA).equals(fs.readFileSync(fileB));
}

function untrackedContentMatches(dirA, dirB) {
  const pathsA = untrackedPaths(dirA);
  const pathsB = untrackedPaths(dirB);
  if (pathsA === null || pathsB === null) return false;
  if (pathsA.length !== pathsB.length) return false;
  for (let i = 0; i < pathsA.length; i += 1) {
    if (pathsA[i] !== pathsB[i]) return false;
  }
  for (const rel of pathsA) {
    try {
      if (!untrackedFileEquals(path.join(dirA, rel), path.join(dirB, rel))) return false;
    } catch (e) {
      return false;
    }
  }
  return true;
}

module.exports = {
  VERDICTS,
  normalizePathForCompare,
  resolveRepoLocation,
  compareRepoIdentity,
  compareRepoContentEquivalence,
};
