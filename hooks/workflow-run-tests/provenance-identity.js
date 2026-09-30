"use strict";
// provenance-identity.js — filesystem identity check for the two authorised
// RUN_CONTRACT emitters (#1273 H2): a same-named file is not this repo's emitter.
//   - path resolves to a real file → it must realpath-match a canonical location.
//   - path resolves to nothing → UNVERIFIED, not trusted (#1273 round 3 / NEW-H2).
//   - relative path climbing out of the working tree → never ours.
// Canonical roots: this module's own checkout, plus the cwd's checkout only when
// it shares this repo's git COMMON dir (hooks/lib/checkout-identity.js; linked
// worktrees share it). A merge-base checkout made by bin/run-tests-baseline is
// never a root (#2431): base-commit output must not complete run_tests.

const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { checkoutRootOf, samePath, realpathOrNull } = require("../lib/checkout-identity");
const { isBaselineCheckout } = require("../lib/baseline-checkout-marker");

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
