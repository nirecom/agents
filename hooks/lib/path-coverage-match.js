"use strict";

// Pure module: unified path-coverage matcher. No I/O.
// An entry with a glob metachar ('*') matches its target via glob (delegated to
// glob-match.js). A non-glob entry matches via path-boundary prefix: the target
// equals the entry, or the target is under the entry's subtree (entry + "/").
// Path canonicalization mirrors glob-match.js's _normalize: absolute-resolve,
// lowercase on Windows, backslash → forward slash. This is the single source of
// truth for both repo-granularity (config.js) and file-granularity
// (shared-cmd-utils.js) exemption checks under ENFORCE_WORKTREE.

const path = require("path");
const { pathMatchesGlob, parseExcludePatterns } = require("./glob-match");
const { normalizeCwd } = require("./path-normalize");

function hasGlobMetachar(s) {
  return typeof s === "string" && s.includes("*");
}

// Canonicalize an absolute path to the comparison form: resolve, lowercase on
// Windows, backslash → forward slash. Mirrors glob-match.js#_normalize.
// normalizeCwd converts POSIX drive-letter paths (/c/foo → C:\foo) on Windows
// before path.resolve, preventing /c/foo from being misresolved to C:\c\foo.
function _canon(p) {
  const normalized = normalizeCwd(String(p)) || String(p);
  let s = path.resolve(normalized);
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
