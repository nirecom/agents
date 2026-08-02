"use strict";

// Two different concerns used to share this file (CPR-3). Only one is still here.
//
// MOVED (#1780 round-5, codex HIGH) — PATH CONTAINMENT across filesystems of
// unknown case-sensitivity now lives in hooks/lib/path-containment.js, because
// hooks/block-off-clearance-write/ asks the same question about the same
// directory and had grown a second, weaker answer (lexical, `win32`-only case
// folding). Re-exported here so existing requirers and
// tests/fix-1780-round4-case-fold-probe.sh keep working unchanged.
//
// STAYS — normalizeTarget() is about the WRITE-TARGET OBJECT SHAPE, not paths.
const {
  isCaseInsensitiveFsAt,
  isContainedUnder,
  _flipCase,
  _probeCaseInsensitive,
} = require("../../lib/path-containment");

// Defensive: the write-target contract is a typed {resolveVia, path} object
// (post-#1400/#1401). A future or missed caller passing a bare string target
// must NOT silently fail-open to "outside scope". Normalize a bare string to the
// safest interpretation — {resolveVia:"ancestor", path: str} — so it is still
// resolved to a repo root and scope-checked (fail-closed toward blocking).
//
// Fail-closed on malformed typed objects: an object present but with a
// missing/non-string `path` used to coerce to String(undefined)="undefined" in
// scope checks, producing a surprising allow/abstain (clean fail-open to
// "outside scope"). Instead, mark it malformed:true so scope predicates treat it
// as in-session / parse-failure (the safe direction → block/abstain), never a
// clean "outside scope" allow.
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
