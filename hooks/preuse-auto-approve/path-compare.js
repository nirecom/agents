"use strict";
// hooks/preuse-auto-approve/path-compare.js — path normalization used by block-capture-echo/remedy.js.

const path = require("path");

// normalizeForCompare collapses backslashes to forward slashes, resolves
// `.`/`..` segments (so a `../../etc` traversal cannot forge an equality
// match), and lowercases the result (so Windows drive-letter casing does not
// defeat the comparison).
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

module.exports = { normalizeForCompare };
