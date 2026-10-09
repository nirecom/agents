"use strict";
// hooks/lib/script-checkout-root.js
// Env-independent trust anchor for the script checkout root (#1630, #2561).
//
// Answers "which directory is the agents checkout that is executing me?" from
// this module's own location only. No environment variable is a candidate: one
// is absent in subagent subprocesses (false BLOCK) and attacker-supplied in the
// hostile case (false ALLOW).
// hooks/lib/load-env.js decides where SETTINGS come from and reads its own
// environment variable for that; only the enumeration and normDir are shared (CPR-SC).
// Circular-dependency note: this module must NOT require load-env.js.

const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("./path-normalize");

// Marker validation is 2-point on purpose: a single marker can be hit by
// coincidence (or planted cheaply), and a candidate that satisfies only one of
// them is ambiguous — ambiguity resolves to the deny side.
const MARKER_FILE = ["hooks", "enforce-worktree.js"];
const MARKER_DIR = ["bin"];

// Windows POSIX normalization (rules/coding/nodejs.md): `/c/git/agents` from Git
// Bash must become a real path before any path.join / fs call. Applied to every
// candidate source and to load-env's own environment read symmetrically (CPR-ORTH).
function normDir(p) {
  if (typeof p !== "string") return null;
  const t = p.trim();
  if (!t) return null;
  try {
    return path.resolve(normalizeCwd(t) || t);
  } catch (_) {
    return null;
  }
}

/**
 * Ordered script-checkout-root candidates.
 *
 * @returns {{dir: string, source: "module"|"realpath"}[]}
 *   `module`   — path.resolve(__dirname, "..", "..") — hooks/lib -> repo root
 *   `realpath` — the same walk after resolving __filename through symlinks
 *                (the ~/.claude/hooks/lib -> agents-repo install layout)
 *
 * SSOT for candidate ENUMERATION only; each consumer owns its selection policy.
 */
function scriptCheckoutRootCandidates() {
  const out = [];
  const moduleDir = normDir(path.resolve(__dirname, "..", ".."));
  if (moduleDir) out.push({ dir: moduleDir, source: "module" });
  try {
    const realDir = normDir(
      path.resolve(path.dirname(fs.realpathSync(__filename)), "..", "..")
    );
    if (realDir) out.push({ dir: realDir, source: "realpath" });
  } catch (_) {
    // realpath resolution failed — drop the candidate, same as load-env's catch.
  }
  return out;
}

/**
 * Pick the first candidate that carries BOTH markers. Test seam.
 *
 * @param {{dir: string, source: string}[]} candidates
 * @param {{existsSync?: (p: string) => boolean}} [opts] — options object, not a bare fn
 * @returns {string|null} the candidate's dir verbatim (already normalized by
 *   scriptCheckoutRootCandidates), or null when no candidate validates. Never invents a path.
 */
function _resolveFromCandidates(candidates, opts) {
  const exists = (opts && opts.existsSync) || fs.existsSync;
  if (!Array.isArray(candidates)) return null;
  for (const c of candidates) {
    if (!c || typeof c.dir !== "string" || !c.dir) continue;
    let valid = false;
    try {
      valid =
        !!exists(path.join(c.dir, ...MARKER_FILE)) &&
        !!exists(path.join(c.dir, ...MARKER_DIR));
    } catch (_) {
      valid = false;
    }
    if (!valid) continue;
    // Log the ADOPTED SOURCE ONLY — never a directory value, so a transcript
    // does not carry the filesystem layout.
    if (process.env.AGENTS_HOOK_DEBUG === "1") {
      process.stderr.write(
        `[script-checkout-root] resolved from source=${c.source}\n`
      );
    }
    return c.dir;
  }
  return null;
}

// Process memoization. Both the positive and the NEGATIVE answer are cached, so
// _resetCacheForTest must clear both (a reset that only clears the success path
// leaves every later case in the process sharing a stale null).
let _cached = null;
let _cachedResolved = false;

/**
 * The validated absolute script checkout root, or null when none can be trusted.
 * Callers stay fail-closed on null.
 */
function resolveScriptCheckoutRoot() {
  if (_cachedResolved) return _cached;
  _cached = _resolveFromCandidates(scriptCheckoutRootCandidates());
  _cachedResolved = true;
  return _cached;
}

function _resetCacheForTest() {
  _cached = null;
  _cachedResolved = false;
}

module.exports = {
  MARKER_FILE,
  MARKER_DIR,
  normDir,
  scriptCheckoutRootCandidates,
  resolveScriptCheckoutRoot,
  _resolveFromCandidates,
  _resetCacheForTest,
};
