"use strict";

// Two different concerns used to share this file (CPR-3). Path containment
// across filesystems of unknown case-sensitivity now lives in
// hooks/lib/path-containment.js — hooks/block-off-clearance-write/ asks the
// same question about the same directory and had grown a second, weaker
// (lexical, win32-only) answer (CPR-2). Re-exported here so existing
// requirers keep working. normalizeTarget() stays: it's about the
// WRITE-TARGET OBJECT SHAPE, not paths.
const {
  isCaseInsensitiveFsAt,
  isContainedUnder,
  _flipCase,
  _probeCaseInsensitive,
} = require("../../lib/path-containment");

// The write-target contract is a typed {resolveVia, path} object. A caller
// passing a bare string must not silently fail-open to "outside scope" — it's
// normalized to {resolveVia:"ancestor", path: str} so it's still resolved and
// scope-checked. An object with a missing/non-string `path` used to coerce to
// String(undefined)="undefined", producing a surprising allow; instead it's
// marked malformed:true so scope predicates treat it as in-session /
// parse-failure — the safe direction — never a clean "outside scope" allow.
function normalizeTarget(t) {
  if (typeof t === "string") return { resolveVia: "ancestor", path: t };
  if (!t || typeof t !== "object" || typeof t.path !== "string") {
    return { malformed: true, resolveVia: "ancestor", path: "" };
  }
  return t;
}

module.exports = {
  isCaseInsensitiveFsAt,
  isContainedUnder,
  normalizeTarget,
  _flipCase,
  _probeCaseInsensitive,
};
