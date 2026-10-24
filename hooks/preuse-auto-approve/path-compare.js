"use strict";
// hooks/preuse-auto-approve/path-compare.js — path comparison shared by the preuse-auto-approve
// judgment and block-capture-echo/remedy.js.

const path = require("path");

// normalizeForCompare collapses backslashes to forward slashes, resolves
// `.`/`..` segments (so a `../../etc` traversal attempt cannot forge a
// prefix match against WORKTREE_BASE_DIR), and lowercases the result (so
// Windows drive-letter casing does not defeat the comparison).
function normalizeForCompare(p) {
  if (typeof p !== "string" || p.length === 0) return "";
  const slashed = p.replace(/\\/g, "/");
  let normalized;
  try {
    normalized = path.posix.normalize(slashed);
  } catch (_e) {
    normalized = slashed;
  }
  // Strip a single trailing slash (except root) so boundary comparison below
  // is consistent regardless of whether the input had one.
  if (normalized.length > 1 && normalized.endsWith("/")) {
    normalized = normalized.slice(0, -1);
  }
  return normalized.toLowerCase();
}

// isInsideBase answers "does candidatePath live under baseDir?" using a
// segment-boundary check (not a bare startsWith), so WORKTREE_BASE_DIR=/foo
// does not falsely match a sibling directory like /foobar.
function isInsideBase(candidatePath, baseDir) {
  const normCandidate = normalizeForCompare(candidatePath);
  const normBase = normalizeForCompare(baseDir);
  if (!normCandidate || !normBase) return false;
  return normCandidate === normBase || normCandidate.startsWith(normBase + "/");
}

module.exports = { normalizeForCompare, isInsideBase };
