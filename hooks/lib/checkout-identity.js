"use strict";
// hooks/lib/checkout-identity.js — "is this directory a checkout of THAT repository?", from git
// metadata alone (file reads, no subprocess).
//
// Repository identity is the git COMMON dir: a main checkout answers `<root>/.git`, and every
// linked worktree answers that same directory, because its `.git` FILE points into
// `<main>/.git/worktrees/<name>` and git records the way back in that directory's `commondir`.
// Shared by the run_tests provenance check and the bash-guard self-script allow resolver.

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
    st = fs.statSync(dotGit);
  } catch (_e) {
    return null;
  }
  if (st.isDirectory()) return realpathOrNull(dotGit);
  if (!st.isFile()) return null;

  let gitdir;
  try {
    const m = /^\s*gitdir:\s*(.+?)\s*$/m.exec(fs.readFileSync(dotGit, "utf8"));
    if (m === null) return null;
    gitdir = path.resolve(root, m[1]);
  } catch (_e) {
    return null;
  }

  // A missing `commondir` falls back to the documented `worktrees/<name>` nesting.
  try {
    const rel = fs.readFileSync(path.join(gitdir, "commondir"), "utf8").trim();
    if (rel !== "") return realpathOrNull(path.resolve(gitdir, rel));
  } catch (_e) { /* no commondir file */ }
  return realpathOrNull(path.resolve(gitdir, "..", ".."));
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
