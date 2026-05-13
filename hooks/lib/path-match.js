const os = require("os");

function normalizeSlashes(p) {
  if (typeof p !== "string" || !p) return "";
  return p.replace(/\\/g, "/");
}

function getBasename(p) {
  const norm = normalizeSlashes(p);
  if (!norm) return "";
  return norm.split("/").pop() || "";
}

function getPathSegments(p) {
  const norm = normalizeSlashes(p);
  if (!norm) return [];
  return norm.split("/").filter(Boolean);
}

function expandHome(p) {
  if (typeof p !== "string" || !p) return "";
  if (p === "~") return normalizeSlashes(os.homedir());
  if (p.startsWith("~/") || p.startsWith("~\\")) {
    return normalizeSlashes(os.homedir()) + "/" + p.slice(2);
  }
  return normalizeSlashes(p);
}

function isUnderPath(p, prefix) {
  if (!p || !prefix) return false;
  const np = normalizeSlashes(expandHome(p));
  const npr = normalizeSlashes(expandHome(prefix));
  const a = process.platform === "win32" ? np.toLowerCase() : np;
  const b = process.platform === "win32" ? npr.toLowerCase() : npr;
  return a === b || a.startsWith(b + "/");
}

module.exports = { normalizeSlashes, getBasename, getPathSegments, expandHome, isUnderPath };
