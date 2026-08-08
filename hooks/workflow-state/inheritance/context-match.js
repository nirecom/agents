"use strict";
// Context guard for inheritance (#1305).
//
// WHY this is a GUARD and not the key: under the lineage-keyed design the donor
// is already proven to be the heir's own ancestor, so cwd+branch no longer
// SELECTS anything. It survives only as a necessary-condition sanity check —
// a continuation that has moved to a different repo or branch is working on
// different code, and the ancestor's completed steps described the old one.
//
// A donor can legitimately hold TWO contexts: the one it started in
// (session_start_context) and the one it ended up in after a `worktree` event
// (the projection). The heir matches if it matches EITHER — but each is
// compared as a PAIR. Mixing one context's cwd with the other's branch would
// describe a place the donor was never in.

const path = require("path");

function samePath(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  let ra;
  let rb;
  try {
    ra = path.resolve(a);
    rb = path.resolve(b);
  } catch (e) {
    return false;
  }
  if (process.platform === "win32") {
    return ra.toLowerCase() === rb.toLowerCase();
  }
  return ra === rb;
}

// resolveDonorContexts(state) → { start, current }, each { cwd, git_branch }.
function resolveDonorContexts(state) {
  const startRaw = (state && state.session_start_context) || {};
  const currentRaw = (state && state.current) || state || {};
  return {
    start: {
      cwd: typeof startRaw.cwd === "string" ? startRaw.cwd : null,
      git_branch: startRaw.git_branch !== undefined ? startRaw.git_branch : null,
    },
    current: {
      cwd: typeof currentRaw.cwd === "string" ? currentRaw.cwd : null,
      git_branch: currentRaw.git_branch !== undefined ? currentRaw.git_branch : null,
    },
  };
}

// contextMatches(heirCtx, donorState) → boolean
function contextMatches(heirCtx, donorState) {
  if (!heirCtx || typeof heirCtx.cwd !== "string") return false;
  const heirBranch = heirCtx.git_branch !== undefined ? heirCtx.git_branch : null;
  const { start, current } = resolveDonorContexts(donorState);
  for (const pair of [current, start]) {
    if (!pair) continue;
    const pairBranch = pair.git_branch !== undefined && pair.git_branch !== null
      ? pair.git_branch
      : null;
    if (pair.cwd === null) {
      // Legacy donors (pre-cwd state files, and every v1 file written before the
      // field existed) record only the branch. Refusing them outright would make
      // the guard reject contexts it simply cannot see, so branch alone decides —
      // but a pair that records NEITHER cwd nor branch is no evidence at all and
      // must never match (that would turn the guard into a pass-through).
      if (pairBranch === null) continue;
      if (pairBranch === (heirBranch ?? null)) return true;
      continue;
    }
    if (pairBranch !== (heirBranch ?? null)) continue;
    if (samePath(pair.cwd, heirCtx.cwd)) return true;
  }
  return false;
}

module.exports = { resolveDonorContexts, contextMatches, samePath };
