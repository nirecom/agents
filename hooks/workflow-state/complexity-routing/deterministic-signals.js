"use strict";
// hooks/workflow-state/complexity-routing/deterministic-signals.js — S1b-wide-change and
// S4-installer for write_code, computed from the WCD-2 write-code list only (#2460). The
// caller passes the bytes of the list's ticket copy; this module never reads the file itself.

const path = require("path");
const { toWindowsPath } = require("../../lib/branch-diff");

const S1B_FILE_THRESHOLD = 8;
const WRITE_CODE_FILES_NAME = "write-code-files.txt";
// Applied to a normalized repo-relative path split on "/".
const S4_PATH_RULES = Object.freeze([
  { name: "install-first-segment", test: (segs) => segs[0] === "install" },
  { name: "dotfiles-segment", test: (segs) => segs.includes("dotfiles") },
]);
const CONTROL_CHAR_RE = /[\u0000-\u001f\u007f]/;

function insideRel(rel) {
  return rel !== "" && rel !== "." && rel !== ".." && !rel.startsWith("../") && !path.posix.isAbsolute(rel);
}

// normalizeWorkPath(raw, repoRoot) -> repo-relative "/" path (lowercased on win32), or null.
function normalizeWorkPath(raw, repoRoot) {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (trimmed === "" || CONTROL_CHAR_RE.test(trimmed)) return null;
  const p = toWindowsPath(trimmed);
  let rel;
  if (path.isAbsolute(p)) {
    if (typeof repoRoot !== "string" || repoRoot === "") return null;
    const r = path.relative(path.resolve(toWindowsPath(repoRoot)), path.resolve(p));
    if (path.isAbsolute(r)) return null;
    rel = path.posix.normalize(r.replace(/\\/g, "/"));
  } else {
    rel = path.posix.normalize(p.replace(/\\/g, "/"));
  }
  rel = rel.replace(/\/+$/, "");
  if (!insideRel(rel)) return null;
  return process.platform === "win32" ? rel.toLowerCase() : rel;
}

// parseWriteCodeFiles(bytes|null, repoRoot) -> {status: "ok"|"missing"|"invalid", paths}.
function parseWriteCodeFiles(bytes, repoRoot) {
  if (bytes === null || bytes === undefined) return { status: "missing", paths: [] };
  const lines = Buffer.from(bytes).toString("utf8").split(/\r?\n/).filter((l) => l.trim() !== "");
  if (lines.length === 0) return { status: "missing", paths: [] };
  const seen = new Set();
  for (const line of lines) {
    const n = normalizeWorkPath(line, repoRoot);
    if (n === null) return { status: "invalid", paths: [] };
    seen.add(n);
  }
  return { status: "ok", paths: Array.from(seen) };
}

function isS4Path(rel) {
  const segs = rel.toLowerCase().split("/");
  return S4_PATH_RULES.some((rule) => rule.test(segs));
}

// computeDeterministic(list) -> {S1b-wide-change, S4-installer} for an ok list, else null.
function computeDeterministic(list) {
  if (!list || list.status !== "ok" || !Array.isArray(list.paths)) return null;
  return {
    "S1b-wide-change": list.paths.length >= S1B_FILE_THRESHOLD,
    "S4-installer": list.paths.some(isS4Path),
  };
}

module.exports = {
  S1B_FILE_THRESHOLD, WRITE_CODE_FILES_NAME, S4_PATH_RULES,
  normalizeWorkPath, parseWriteCodeFiles, computeDeterministic,
};
