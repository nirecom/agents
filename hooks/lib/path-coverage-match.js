"use strict";

// Unified path-coverage matcher used by both the gate-skip check
// (precommit-exclude-check.js) and the enforcement hooks (config.js,
// shared-cmd-utils.js). Resolves symlinks on both sides via realResolve
// (path-containment.js SSOT) so a symlink-based ENFORCE_WORKTREE_EXCLUDE
// entry or a symlinked target cannot cause asymmetric gate/enforcement
// behaviour (CPR-ORTH / CPR-SSOT).
// An entry with a glob metachar ('*') matches its target via glob (delegated to
// glob-match.js). A non-glob entry matches via path-boundary prefix: the target
// equals the entry, or the target is under the entry's subtree (entry + "/").

const path = require("path");
const { pathMatchesGlob, parseExcludePatterns } = require("./glob-match");
const { normalizeCwd } = require("./path-normalize");
const { realResolve } = require("./path-containment");

function hasGlobMetachar(s) {
  return typeof s === "string" && s.includes("*");
}

// Canonicalize an absolute path to the comparison form: physically resolve
// symlinks (realResolve — falls back to lexical resolve on adversarial chains),
// lowercase on Windows, backslash → forward slash. Mirrors glob-match.js#_normalize.
// normalizeCwd converts POSIX drive-letter paths on Windows before resolution
// (Git-Bash form to native Windows form) so that drive-letter paths resolve correctly.
function _canon(p) {
  const normalized = normalizeCwd(String(p)) || String(p);
  let s;
  try {
    s = realResolve(normalized);
  } catch (_) {
    s = path.resolve(normalized); // fallback: adversarial symlink chain (>40 hops)
  }
  if (process.platform === "win32") s = s.toLowerCase();
  s = s.replace(/\\/g, "/");
  return s;
}

// True when targetPath is covered by ANY entry in the semicolon-delimited
// entryList. Glob entries match via glob; plain entries via path-boundary prefix.
function isCoveredByEntryList(entryList, targetPath) {
  if (typeof targetPath !== "string" || targetPath.length === 0) return false;
  const entries = parseExcludePatterns(entryList);
  if (entries.length === 0) return false;
  let normTarget = null;
  for (const entry of entries) {
    if (hasGlobMetachar(entry)) {
      // Glob path: delegate to glob-match.js (it applies its own normalization).
      if (pathMatchesGlob(targetPath, entry)) return true;
    } else {
      // Plain path-boundary prefix path.
      if (normTarget === null) normTarget = _canon(targetPath);
      const normEntry = _canon(entry);
      if (normTarget === normEntry || normTarget.startsWith(normEntry + "/")) return true;
    }
  }
  return false;
}

module.exports = { isCoveredByEntryList, hasGlobMetachar };
