"use strict";
// provenance-identity.js — filesystem identity check for the two authorised
// RUN_CONTRACT emitters (#1273 H2): a same-named file is not this repo's emitter.
//   - path resolves to a real file → it must realpath-match a canonical location.
//   - path resolves to nothing → UNVERIFIED, not trusted (#1273 round 3 / NEW-H2).
//   - relative path climbing out of the working tree → never ours.
// Canonical roots: this module's own checkout, plus the cwd's checkout only when
// it shares this repo's git COMMON dir (#1273 round 3 / NEW-M1; linked worktrees
// share it). A merge-base checkout made by bin/run-tests-baseline is never a
// root (#2431): base-commit output must not complete run_tests.

const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { isBaselineCheckout } = require("../lib/baseline-checkout-marker");

// <root>/hooks/workflow-run-tests/provenance-identity.js → <root>
const MODULE_REPO_ROOT = path.resolve(__dirname, "..", "..");

// emitter token (as returned by resolveTestProvenance) → its location in a repo.
const CANONICAL_RELPATH = new Map([
  ["run-all", "tests/run-all.sh"],
  ["worker-dispatch", "bin/worker-dispatch.js"],
]);

const MAX_ROOT_WALK = 40;

// Windows paths compare case-insensitively; POSIX paths do not.
function samePath(a, b) {
  if (process.platform === "win32") return a.toLowerCase() === b.toLowerCase();
  return a === b;
}

function toFsPath(value) {
  const s = String(value === null || value === undefined ? "" : value);
  if (s === "") return "";
  return normalizeCwd(s) || s;
}

function realpathOrNull(p) {
  try {
    return fs.realpathSync(p);
  } catch (e) {
    return null;
  }
}

// The git COMMON dir of the checkout rooted at `root`, or null when `root` is
// not a checkout. A main checkout answers `<root>/.git`; a linked worktree's
// `.git` FILE points into `<main>/.git/worktrees/…`, whose `commondir` file
// records the way back to that same directory.
function gitCommonDir(root) {
  const dotGit = path.join(root, ".git");
  let st;
  try {
    st = fs.statSync(dotGit);
  } catch (e) {
    return null;
  }
  if (st.isDirectory()) return realpathOrNull(dotGit);
  if (!st.isFile()) return null;

  let gitdir;
  try {
    const m = /^\s*gitdir:\s*(.+?)\s*$/m.exec(fs.readFileSync(dotGit, "utf8"));
    if (m === null) return null;
    gitdir = path.resolve(root, m[1]);
  } catch (e) {
    return null;
  }

  // `<gitdir>/commondir` holds the (usually relative) way back to `<main>/.git`.
  // Absent — an unusual layout — falls back to the documented `worktrees/<name>`
  // nesting rather than guessing.
  try {
    const rel = fs.readFileSync(path.join(gitdir, "commondir"), "utf8").trim();
    if (rel !== "") return realpathOrNull(path.resolve(gitdir, rel));
  } catch (e) {}
  return realpathOrNull(path.resolve(gitdir, "..", ".."));
}

const MODULE_GIT_COMMON_DIR = gitCommonDir(MODULE_REPO_ROOT);

// Nearest ancestor of `startDir` that is a checkout of THIS repository, or null.
// The walk stops at the first `.git` it meets: a nested unrelated repo is an
// answer ("this is not ours"), not a reason to keep climbing into whatever
// happens to enclose it.
function findRepoRoot(startDir) {
  let dir = startDir;
  for (let i = 0; i < MAX_ROOT_WALK && typeof dir === "string" && dir !== ""; i++) {
    let hasGit = false;
    try {
      hasGit = fs.existsSync(path.join(dir, ".git"));
    } catch (e) {
      return null;
    }
    if (hasGit) {
      if (MODULE_GIT_COMMON_DIR === null) return null;
      const common = gitCommonDir(dir);
      return common !== null && samePath(common, MODULE_GIT_COMMON_DIR) ? dir : null;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

/**
 * Is `claimedPath` really this repo's `emitter`?
 *
 * @param {"run-all"|"worker-dispatch"} emitter
 * @param {string} claimedPath - the execution-position token as written
 * @param {string} [cwd] - the cwd the command ran in (Bash tool cwd or process cwd)
 * @returns {boolean}
 */
function verifyEmitterIdentity(emitter, claimedPath, cwd) {
  const rel = CANONICAL_RELPATH.get(emitter);
  if (rel === undefined) return false;

  const raw = toFsPath(claimedPath);
  if (raw === "") return false;

  let baseCwd;
  try {
    baseCwd = toFsPath(cwd) || process.cwd();
  } catch (e) {
    return false;
  }

  let resolved;
  try {
    resolved = path.resolve(baseCwd, raw);
    if (!path.isAbsolute(raw)) {
      // A relative spelling that escapes the working tree names something the
      // tree does not own — never this repo's emitter.
      const fromCwd = path.relative(baseCwd, resolved);
      if (fromCwd === ".." || fromCwd.startsWith(`..${path.sep}`)) return false;
    }
  } catch (e) {
    return false;
  }

  const real = realpathOrNull(resolved);
  if (real === null) return false; // nothing there: unverified, so not trusted

  const roots = [MODULE_REPO_ROOT];
  const cwdRoot = findRepoRoot(baseCwd);
  if (cwdRoot !== null) roots.push(cwdRoot);

  for (const root of roots) {
    if (isBaselineCheckout(root)) continue;
    const canonical = realpathOrNull(path.join(root, rel));
    if (canonical !== null && samePath(canonical, real)) return true;
  }
  return false;
}

module.exports = {
  verifyEmitterIdentity,
  MODULE_REPO_ROOT,
};
