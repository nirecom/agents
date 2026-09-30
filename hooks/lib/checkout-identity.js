"use strict";
// hooks/lib/checkout-identity.js — "is this directory a checkout of THAT repository?", from git
// metadata alone (no subprocess). Shared by run_tests provenance and the bash-guard allow resolver.
// Identity is the git COMMON dir: a main checkout's `<root>/.git`, or, for a linked worktree whose
// `.git` FILE points at `<common>/worktrees/<name>`, the dir that registration's `commondir` names.
// A one-line `gitdir:` pointer is forgeable, so it counts only when git's registration agrees: the
// gitdir is a direct child of `<common>/worktrees/`, has a `commondir`, and its `gitdir`
// back-reference names THIS `.git`. A `.git` that is itself a symlink or junction is rejected.

const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("./path-normalize");

const MAX_ROOT_WALK = 40;

// Windows paths compare case-insensitively; POSIX paths do not.
function samePath(a, b) {
  if (process.platform === "win32") return a.toLowerCase() === b.toLowerCase();
  return a === b;
}

function realpathOrNull(p) {
  try {
    return fs.realpathSync(p);
  } catch (_e) {
    return null;
  }
}

/**
 * @param {string} root a directory that may be a checkout root
 * @returns {string|null} the realpath of its git common dir, or null when it is not a checkout
 */
function gitCommonDir(root) {
  const dotGit = path.join(root, ".git");
  let st;
  try {
    st = fs.lstatSync(dotGit);
  } catch (_e) {
    return null;
  }
  if (st.isSymbolicLink()) return null;
  const realDotGit = realpathOrNull(dotGit);
  if (realDotGit === null) return null;

  if (st.isDirectory()) {
    const realRoot = realpathOrNull(root);
    if (realRoot === null || !samePath(realDotGit, path.join(realRoot, ".git"))) return null;
    return realDotGit;
  }
  if (!st.isFile()) return null;
  return linkedWorktreeCommonDir(dotGit, realDotGit, root);
}

function readTrimmedOrEmpty(p) {
  try {
    return fs.readFileSync(p, "utf8").trim();
  } catch (_e) {
    return "";
  }
}

// `.git` FILE form: accept only when git's registration of the worktree agrees (see header).
function linkedWorktreeCommonDir(dotGit, realDotGit, root) {
  const m = /^\s*gitdir:\s*(.+?)\s*$/m.exec(readTrimmedOrEmpty(dotGit));
  if (m === null) return null;
  const gitdir = realpathOrNull(path.resolve(root, normalizeCwd(m[1]) || m[1]));
  if (gitdir === null) return null;

  const rel = readTrimmedOrEmpty(path.join(gitdir, "commondir"));
  if (rel === "") return null;
  const common = realpathOrNull(path.resolve(gitdir, rel));
  if (common === null || !samePath(path.dirname(gitdir), path.join(common, "worktrees"))) return null;

  // `git worktree add --relative-paths` writes the back-reference relative to the gitdir.
  const backref = readTrimmedOrEmpty(path.join(gitdir, "gitdir"));
  if (backref === "") return null;
  const realBackref = realpathOrNull(path.resolve(gitdir, normalizeCwd(backref) || backref));
  if (realBackref === null || !samePath(realBackref, realDotGit)) return null;
  return common;
}

/**
 * Nearest ancestor of `startPath` (inclusive) that holds a `.git`, when it is a checkout of the
 * same repository as `anchorRoot`. The walk stops at the first `.git`: a nested unrelated repo is
 * an answer ("not ours"), never a reason to keep climbing.
 *
 * @param {string} startPath
 * @param {string} anchorRoot a checkout root of the repository to match
 * @returns {string|null} that checkout's root (as walked from startPath), or null
 */
function checkoutRootOf(startPath, anchorRoot) {
  try {
    if (typeof startPath !== "string" || startPath === "") return null;
    if (typeof anchorRoot !== "string" || anchorRoot === "") return null;
    const anchorCommon = gitCommonDir(normalizeCwd(anchorRoot) || anchorRoot);
    if (anchorCommon === null) return null;
    let dir = normalizeCwd(startPath) || startPath;
    for (let i = 0; i < MAX_ROOT_WALK && dir !== ""; i++) {
      if (fs.existsSync(path.join(dir, ".git"))) {
        const common = gitCommonDir(dir);
        return common !== null && samePath(common, anchorCommon) ? dir : null;
      }
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
    return null;
  } catch (_e) {
    return null;
  }
}

module.exports = { gitCommonDir, checkoutRootOf, samePath, realpathOrNull, MAX_ROOT_WALK };
