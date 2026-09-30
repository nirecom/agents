"use strict";
// provenance-identity.js — is the path a RUN_CONTRACT emitter was reached by really THIS repo's
// emitter (#1273 H2)? A path suffix or basename is a name, not an identity.
// - A real file must realpath-match a canonical emitter location; otherwise it is an impostor.
// - A path that resolves to nothing is UNVERIFIED and never trusted: the hook reads strings, it
//   executes nothing, so "could not check" must not unlock a completion (#1273 round 3).
// - A relative path that climbs out of the working tree is never this repo's emitter.
// Canonical roots: the module's own root, plus the checkout above cwd only when it is the SAME
// repository by git common dir (hooks/lib/checkout-identity.js) — a fresh `git init` is not ours.

const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { checkoutRootOf, samePath, realpathOrNull } = require("../lib/checkout-identity");

// <root>/hooks/workflow-run-tests/provenance-identity.js → <root>
const MODULE_REPO_ROOT = path.resolve(__dirname, "..", "..");

// emitter token (as returned by resolveTestProvenance) → its location in a repo.
const CANONICAL_RELPATH = new Map([
  ["run-all", "tests/run-all.sh"],
  ["worker-dispatch", "bin/worker-dispatch.js"],
]);

function toFsPath(value) {
  const s = String(value === null || value === undefined ? "" : value);
  if (s === "") return "";
  return normalizeCwd(s) || s;
}

// Nearest ancestor of `startDir` that is a checkout of THIS repository, or null.
const findRepoRoot = (startDir) => checkoutRootOf(startDir, MODULE_REPO_ROOT);

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
