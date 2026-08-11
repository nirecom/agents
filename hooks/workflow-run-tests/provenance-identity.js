"use strict";
// provenance-identity.js — filesystem identity check for the two authorised
// RUN_CONTRACT emitters (#1273 H2).
//
// WHY (CPR-WPH): resolveTestProvenance() decides WHO produced the output by
// comparing a resolved execution position against a path SUFFIX
// (`tests/run-all.sh`) or a dispatcher BASENAME (`worker-dispatch.js`). A name is
// not an identity: any file that happens to be spelled that way, anywhere on
// disk, inherits the emitter's whole authority — and that authority plus a
// hand-written contract line is a complete run_tests completion. This module
// adds the missing question: is the thing at that path actually THIS repo's
// emitter?
//
// The judgement is deliberately three-valued in its inputs, not two (CPR-SC):
//   - the path resolves to a REAL file → it must realpath-match a canonical
//     emitter location, otherwise it is a same-named impostor (the attack).
//   - the path resolves to NOTHING → UNVERIFIED, therefore not trusted (#1273
//     round 3 / NEW-H2). The older reading — "a file that does not exist cannot
//     have executed, so the suffix judgement stands" — is false for this caller:
//     the hook never executes anything. It reads a command STRING and a stdout
//     STRING that the same author supplied, so `bash /nowhere/tests/run-all.sh`
//     plus a hand-written contract line was a complete run_tests completion.
//     "I could not check this" and "I checked it and it is ours" are different
//     answers, and only the second one may unlock a completion.
//   - the path is RELATIVE and climbs out of the working tree (`../..//…`) → it
//     names something the working tree does not own, so it is never this
//     repo's emitter regardless of whether it exists.
//
// Two canonical roots are accepted, never one: the root this module itself lives
// in (the deployed copy) and the root above the caller's cwd (the checkout the
// command actually ran in). Pinning only the former would demote every legitimate
// run made from a different checkout — but the second root is admitted only when
// it is demonstrably a checkout of the SAME repository (#1273 round 3 / NEW-M1).
// "Is there a repo here?" is not "is this THIS repo?": a two-second `git init` in
// a temp directory otherwise minted a fully authorised emitter. Repo identity is
// taken from the git COMMON dir, which a linked worktree (`.git` is a FILE
// holding `gitdir: …/.git/worktrees/<name>`) shares with its main checkout — the
// everyday shape for this repo, and the case a bare `root === MODULE_REPO_ROOT`
// check would break.

const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");

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
// not a checkout. This is the repository's identity: a main checkout answers
// `<root>/.git`, and every linked worktree of the same repository answers that
// same directory, because its `.git` FILE points into `<main>/.git/worktrees/…`
// and git records the way back in that directory's `commondir` file.
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
    const canonical = realpathOrNull(path.join(root, rel));
    if (canonical !== null && samePath(canonical, real)) return true;
  }
  return false;
}

module.exports = {
  verifyEmitterIdentity,
  MODULE_REPO_ROOT,
};
