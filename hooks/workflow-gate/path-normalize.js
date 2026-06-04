"use strict";
// Windows path normalization: converts Unix-style drive paths (/c/foo) and
// forward-slash Windows paths (C:/foo) to canonical backslash form (C:\foo).

// Normalize Unix-style drive paths and Windows forward-slash paths to canonical
// platform form. Returns input unchanged for already-canonical or POSIX paths.
function normalizeForWindows(p) {
  if (!p) return p;
  const driveMatch = p.match(/^\/([a-zA-Z])(\/.*)?$/);
  if (driveMatch) {
    const drive = driveMatch[1].toUpperCase();
    const rest = driveMatch[2] || "";
    return drive + ":\\" + rest.replace(/\//g, "\\").replace(/^\\/, "");
  }
  if (process.platform === "win32" && /^[a-zA-Z]:\//.test(p)) return p.replace(/\//g, "\\");
  return p;
}

module.exports = { normalizeForWindows };
