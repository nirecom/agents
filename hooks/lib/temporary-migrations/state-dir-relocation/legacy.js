"use strict";
// Temporary (#2511): deleted with this folder per the deletion-condition in state-root.js
// The legacy state root and the M1 test "does this session still live there".
// The single commit point of a relocation is <newRoot>/<sid>.json: the caller checks it
// first, so a new-root <sid>.control (published before the json) never decides here.
const fs = require("fs");
const path = require("path");

function LEGACY_ROOT(home) {
  return path.join(home, ".claude", "projects", "workflow");
}

// The `<sid>-<suffix>` names a canonical writer puts in the state root. None exists
// today (turn markers are `<sid>.confirm-plan-turn-*`); a bare `<sid>-` prefix would
// claim another session whose sid extends this one (`X` vs `X-other`).
const SID_DASH_SUFFIXES = Object.freeze([]);

// The `<sid>.<suffix>` names a canonical writer puts in the state root. A dot is legal
// inside a sid, so a bare `<sid>.` prefix would claim another session `X.Y` for `X`
// (its `X.Y.json`, `X.Y.control`): only these exact suffixes belong to <sid>.
// Writers: state-io (json, control, instructions-loaded), session markers and
// protected-basenames.js (OFF markers, off-clearance tokens), request-off-clearance.d/
// mint-token.js (off-clearance mint tmp), gh-env-state.js (gh-*), turn-marker.js
// (confirm-plan-turn-*). No writer creates a bare `<sid>`. Keep in step when a writer adds a kind.
const SID_DOT_SUFFIXES = Object.freeze([
  "json", "control", "instructions-loaded",
  "workflow-off", "worktree-off", "issue-close-verified", "next-step-paused",
  "stall-reported", "off-emergency-invoked",
  "gh-login", "gh-env", "gh-auth-dirty",
  "off-clearance", "off-clearance.claimed", "off-clearance.mint", "off-clearance.mint.claimed",
]);
const TURN_MARKER_RE = /^confirm-plan-turn-[A-Za-z0-9_-]+\.json$/;
// Transient tails a writer leaves beside one of those names: the state lock, the
// tmp+rename spellings (`.tmp`, `.<pid>.tmp`, `.<pid>.<n>.tmp`), the exact-consume
// claim (`.consuming-<hex>.tmp`), the mint lock's tmp (`.mint.lock.tmp`) and the mint
// staging tmp (`.mint.<pid>.<12hex>.tmp`).
const TRANSIENT_TAIL_RE = /(?:\.lock|\.tmp|\.\d+\.tmp|\.\d+\.\d+\.tmp|\.consuming-[0-9a-f]+\.tmp|\.mint\.lock\.tmp|\.mint\.\d+\.[0-9a-f]+\.tmp)$/;

function isOwnedSuffix(rest) {
  return SID_DOT_SUFFIXES.includes(rest) || TURN_MARKER_RE.test(rest);
}

// The suffix after `<sid>.` when name is one of <sid>'s entries, else null.
function sidEntryRest(name, sid) {
  if (!name.startsWith(`${sid}.`)) return null;
  const rest = name.slice(sid.length + 1);
  if (isOwnedSuffix(rest)) return rest;
  const m = TRANSIENT_TAIL_RE.exec(rest);
  return m !== null && isOwnedSuffix(rest.slice(0, m.index)) ? rest : null;
}

// The one matcher for "this top-level state-root entry belongs to <sid>".
function isSidEntry(name, sid) {
  if (SID_DASH_SUFFIXES.some((s) => name === `${sid}-${s}`)) return true;
  return sidEntryRest(name, sid) !== null;
}

// The one-shot OFF-clearance family (token, claim, mint lock and tmps) of <sid>.
function isOffClearanceEntry(name, sid) {
  const rest = sidEntryRest(name, sid);
  return rest !== null && (rest === "off-clearance" || rest.startsWith("off-clearance."));
}

// A sid that is itself one of another session's entry names (`<A>.json`, `<A>.control`).
function isEntryShapedSid(sid) {
  for (let i = sid.indexOf("."); i > 0; i = sid.indexOf(".", i + 1)) {
    if (isSidEntry(sid, sid.slice(0, i))) return true;
  }
  return false;
}

function isLegacySession(sid, { newRoot, home }) {
  if (fs.existsSync(path.join(newRoot, `${sid}.json`))) return false;
  const legacyRoot = LEGACY_ROOT(home);
  return fs.existsSync(path.join(legacyRoot, `${sid}.json`)) || fs.existsSync(path.join(legacyRoot, `${sid}.control`));
}

module.exports = {
  LEGACY_ROOT, SID_DASH_SUFFIXES, isSidEntry, isOffClearanceEntry, isEntryShapedSid, isLegacySession,
};
