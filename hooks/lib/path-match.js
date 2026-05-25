const os = require("os");
const path = require("path");

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

function expandHomeAndEnvVars(p) {
  if (typeof p !== "string" || !p) return "";
  const home = normalizeSlashes(os.homedir());
  if (p === "~") return home;
  if (p.startsWith("~/") || p.startsWith("~\\")) return home + "/" + p.slice(2);
  const envForms = [
    { re: /^\$HOME(?=\/|\\|$)/, replace: home },
    { re: /^\$\{HOME\}(?=\/|\\|$)/, replace: home },
    { re: /^\$USERPROFILE(?=\/|\\|$)/, replace: home },
    { re: /^\$\{USERPROFILE\}(?=\/|\\|$)/, replace: home },
  ];
  for (const { re, replace } of envForms) {
    if (re.test(p)) return normalizeSlashes(p.replace(re, replace));
  }
  return normalizeSlashes(p);
}

function isUnderAnyRoot(p, roots, extraLiteralRoots) {
  if (typeof p !== "string" || !p) return false;
  const collapsed = path.posix.normalize(expandHomeAndEnvVars(p));
  const subject = process.platform === "win32" ? collapsed.toLowerCase() : collapsed;
  const all = [...(roots || []), ...(extraLiteralRoots || [])];
  for (const r of all) {
    const expanded = path.posix.normalize(expandHomeAndEnvVars(r));
    const root = process.platform === "win32" ? expanded.toLowerCase() : expanded;
    if (subject === root || subject.startsWith(root + "/")) return true;
  }
  return false;
}

function globMatchesUnder(pattern, roots) {
  if (typeof pattern !== "string" || !pattern) return false;
  const s = normalizeSlashes(pattern);
  const subject = process.platform === "win32" ? s.toLowerCase() : s;
  for (const r of roots || []) {
    const parts = normalizeSlashes(r).replace(/\/+$/, "").split("/");
    // Use the first dot-prefixed component as needle to avoid false positives
    // for generic filenames like config.json or credentials that appear inside
    // multi-level roots like ~/.docker/config.json or ~/.gem/credentials.
    const hiddenPart = parts.find((p) => p.startsWith("."));
    if (!hiddenPart) continue;
    const needle = process.platform === "win32" ? hiddenPart.toLowerCase() : hiddenPart;
    if (
      subject.includes("/" + needle + "/") ||
      subject.endsWith("/" + needle) ||
      subject === "~/" + needle ||
      subject === needle ||
      subject.startsWith("~/" + needle + "/") ||
      subject.startsWith(needle + "/")
    ) return true;
  }
  return false;
}

module.exports = { normalizeSlashes, getBasename, getPathSegments, expandHome, expandHomeAndEnvVars, isUnderPath, isUnderAnyRoot, globMatchesUnder };
