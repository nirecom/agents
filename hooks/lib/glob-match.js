"use strict";

// Pure module: semicolon-separated pattern parsing + ** / * glob matching.
// No I/O. Cross-platform path normalization (Windows backslash → forward slash).

function parseExcludePatterns(str) {
  if (!str || typeof str !== "string") return [];
  return str.split(";").map((s) => s.trim()).filter((s) => s.length > 0);
}

function _normalize(p) {
  let s = String(p).replace(/\\/g, "/");
  if (process.platform === "win32") s = s.toLowerCase();
  return s;
}

// Bounds on pattern complexity: unbounded alternating wildcard/literal globs
// (e.g. "**a**a**a...z") drive the emitted regex into catastrophic backtracking
// (CWE-1333) against a non-matching target. Patterns over either limit are
// treated as non-matching rather than compiled, which fails toward "run the
// full language check" (the safe direction), never toward a silent skip.
const MAX_PATTERN_LENGTH = 1024;
const MAX_WILDCARD_COUNT = 10;

function _isPatternSafe(pattern) {
  if (pattern.length > MAX_PATTERN_LENGTH) return false;
  let stars = 0;
  for (let i = 0; i < pattern.length; i++) {
    if (pattern[i] === "*") stars++;
  }
  return stars <= MAX_WILDCARD_COUNT;
}

function _globToRegExp(pattern) {
  const norm = _normalize(pattern);
  let re = "";
  let i = 0;
  while (i < norm.length) {
    const c = norm[i];
    if (c === "*") {
      if (norm[i + 1] === "*") {
        // **/ matches zero or more path segments (gitignore-style: **/x.md matches x.md and a/b/x.md)
        if (norm[i + 2] === "/") { re += "(?:.*/)?"; i += 3; }
        else { re += ".*"; i += 2; }
      } else {
        re += "[^/]*";
        i += 1;
      }
    } else if (/[.+^$(){}|[\]\\?]/.test(c)) {
      re += "\\" + c;
      i += 1;
    } else {
      re += c;
      i += 1;
    }
  }
  return new RegExp("^" + re + "$");
}

function pathMatchesGlob(filePath, pattern) {
  if (!pattern) return false;
  if (!_isPatternSafe(pattern)) return false;
  const target = _normalize(filePath);
  return _globToRegExp(pattern).test(target);
}

function matchesAnyExcludePattern(filePath, patterns) {
  if (!Array.isArray(patterns) || patterns.length === 0) return false;
  for (const p of patterns) if (pathMatchesGlob(filePath, p)) return true;
  return false;
}

module.exports = { parseExcludePatterns, pathMatchesGlob, matchesAnyExcludePattern };
