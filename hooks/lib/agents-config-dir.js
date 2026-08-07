"use strict";
// hooks/lib/agents-config-dir.js
// Env-independent trust anchor for the agents config dir (#1630).
//
// Hook predicates that identify a sanctioned script by `<config-dir>/<rel>` used
// to read process.env.AGENTS_CONFIG_DIR directly. That value is absent in
// subagent / Bash-tool subprocess environments (false BLOCK) and attacker-supplied
// in the hostile case (false ALLOW). This module answers the question
// "which directory is the agents checkout that is executing me?" from evidence
// that does not depend on the environment being intact.
//
// Deliberate policy asymmetry with hooks/lib/load-env.js (CPR-SC): both consume
// configDirCandidates(), but only the CANDIDATE ENUMERATION is shared —
//   resolveAgentsConfigDir : env -> module -> realpath  (falls through)
//   loadDefaultEnv         : env only                   (short-circuits)
// load-env decides where SETTINGS come from (an explicit AGENTS_CONFIG_DIR must
// stay the sole config source, or a test/alternate config dir would silently get
// the real repo's .env injected); this resolver decides WHO is executing, where a
// broken env value must lose to a verified module anchor. Do not "unify" them —
// tests/fix-389-load-env-default-fallback/config-dir-cases.sh T389-7 pins it.
//
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
// Bash must become a real path before any path.join / fs call. Applied to all
// three candidate sources symmetrically (CPR-ORTH).
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
 * Ordered config-dir candidates, most-explicit first.
 *
 * @returns {{dir: string, source: "env"|"module"|"realpath"}[]}
 *   `env`      — process.env.AGENTS_CONFIG_DIR (present only when non-empty after trim)
 *   `module`   — path.resolve(__dirname, "..", "..") — hooks/lib -> repo root
 *   `realpath` — the same walk after resolving __filename through symlinks
 *                (the ~/.claude/hooks/lib -> agents-repo install layout)
 *
 * SSOT for candidate ENUMERATION only. The selection policy belongs to each
 * consumer and is intentionally different between them (see the header note).
 */
function configDirCandidates() {
  const out = [];
  const envDir = normDir(process.env.AGENTS_CONFIG_DIR);
  if (envDir) out.push({ dir: envDir, source: "env" });
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
 *   configDirCandidates), or null when no candidate validates. Never invents a path.
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
    // Log the ADOPTED SOURCE ONLY — never a directory value. A rejected
    // AGENTS_CONFIG_DIR is attacker- or misconfiguration-controlled text, and
    // echoing it into a transcript leaks the filesystem layout.
    if (process.env.AGENTS_HOOK_DEBUG === "1" && c.source !== "env") {
      process.stderr.write(
        `[agents-config-dir] config dir resolved from source=${c.source}\n`
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
 * The validated absolute agents config dir, or null when none can be trusted.
 * Callers stay fail-closed on null (`if (!acd) return false;`).
 */
function resolveAgentsConfigDir() {
  if (_cachedResolved) return _cached;
  _cached = _resolveFromCandidates(configDirCandidates());
  _cachedResolved = true;
  return _cached;
}

function _resetCacheForTest() {
  _cached = null;
  _cachedResolved = false;
}

module.exports = {
  configDirCandidates,
  resolveAgentsConfigDir,
  _resolveFromCandidates,
  _resetCacheForTest,
};
