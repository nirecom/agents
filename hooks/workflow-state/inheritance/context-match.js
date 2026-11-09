"use strict";
// Context guard for inheritance (#1305). Lineage already proves the session-upstream
// is the session-downstream's ancestor, so cwd+branch only sanity-checks that the
// continuation still works on the same repo and branch.
//
// A session-upstream may hold TWO contexts (session_start_context and the post-`worktree`
// projection). The session-downstream matches if it matches EITHER, each compared as a
// cwd+branch PAIR — mixing them would describe a place the session-upstream never was.

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

// resolveUpstreamContexts(state) → { start, current }, each { cwd, git_branch }.
function resolveUpstreamContexts(state) {
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

// contextMatches(downstreamCtx, upstreamState) → boolean
function contextMatches(downstreamCtx, upstreamState) {
  if (!downstreamCtx || typeof downstreamCtx.cwd !== "string") return false;
  const downstreamBranch = downstreamCtx.git_branch !== undefined ? downstreamCtx.git_branch : null;
  const { start, current } = resolveUpstreamContexts(upstreamState);
  for (const pair of [current, start]) {
    if (!pair) continue;
    const pairBranch = pair.git_branch !== undefined && pair.git_branch !== null
      ? pair.git_branch
      : null;
    if (pair.cwd === null) {
      // Legacy session-upstreams (pre-cwd state files, and every v1 file written before the
      // field existed) record only the branch. Refusing them outright would make
      // the guard reject contexts it simply cannot see, so branch alone decides —
      // but a pair that records NEITHER cwd nor branch is no evidence at all and
      // must never match (that would turn the guard into a pass-through).
      if (pairBranch === null) continue;
      if (pairBranch === (downstreamBranch ?? null)) return true;
      continue;
    }
    if (pairBranch !== (downstreamBranch ?? null)) continue;
    if (samePath(pair.cwd, downstreamCtx.cwd)) return true;
  }
  return false;
}

module.exports = { resolveUpstreamContexts, contextMatches, samePath };
