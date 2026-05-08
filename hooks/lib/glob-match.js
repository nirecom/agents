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
  const target = _normalize(filePath);
  return _globToRegExp(pattern).test(target);
}

function matchesAnyExcludePattern(filePath, patterns) {
  if (!Array.isArray(patterns) || patterns.length === 0) return false;
  for (const p of patterns) if (pathMatchesGlob(filePath, p)) return true;
  return false;
}

module.exports = { parseExcludePatterns, pathMatchesGlob, matchesAnyExcludePattern };
