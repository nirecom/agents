// Pure append-only-document-family detection (canonical docs/history.md +
// CHANGELOG.md and their rotated archives). Consumer:
// hooks/block-history-direct.js.
"use strict";

const { parse } = require("./command-ir");
const { collectWriteTargetsFromSegments, SHELL_CONFIG_VERB_SET } = require("./bash-write-targets");

// Case-insensitive: Windows filesystems are case-insensitive, so
// `Docs/History/2026.md` must not slip past (CPR-UNV).
const PROTECTED_PATTERNS = [
  /(^|\/)docs\/history\.md$/i,          // canonical history
  /(^|\/)changelog\.md$/i,              // canonical changelog
  /(^|\/)docs\/history\/[^/]+\.md$/i,   // rotated history archives
  /(^|\/)changelog\/[^/]+\.md$/i,       // rotated changelog archives (incl. docs/changelog/)
];

// Rule documents that merely share a name with the protected family.
const EXCLUDED_PATTERNS = [
  /(^|\/)rules\/docs\/history\.md$/i,
  /(^|\/)rules\/docs\/changelog\.md$/i,
];

// Normalize separators and collapse `.` / `..` segments so that
// `docs/history/../history/2026.md` is judged as `docs/history/2026.md`.
function normalizePath(filePath) {
  const segments = String(filePath).replace(/\\/g, "/").split("/");
  const out = [];
  for (const seg of segments) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") { out.pop(); continue; }
    out.push(seg);
  }
  return out.join("/");
}

// Single predicate shared by the tool-write path and the shell path — never
// add a second one; both call sites must stay symmetric (CPR-ORTH).
function isProtectedPath(filePath) {
  if (!filePath || typeof filePath !== "string") return false;
  const norm = normalizePath(filePath);
  if (!norm) return false;
  if (EXCLUDED_PATTERNS.some((re) => re.test(norm))) return false;
  return PROTECTED_PATTERNS.some((re) => re.test(norm));
}

function bashHitsProtected(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const ir = parse(cmd);
  if (!ir || ir.parseFailure) return false;
  const { targets } = collectWriteTargetsFromSegments(ir.segments, { verbs: SHELL_CONFIG_VERB_SET });
  if (!targets) return false;
  return targets.some((t) => isProtectedPath(t.path));
}

module.exports = {
  PROTECTED_PATTERNS,
  EXCLUDED_PATTERNS,
  normalizePath,
  isProtectedPath,
  bashHitsProtected,
};
