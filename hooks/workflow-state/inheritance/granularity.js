"use strict";
// How much of a session upstream's record may travel is a fact about WHERE the
// session downstream runs (#2297), never a caller's choice: only the very same
// checkout keeps the worktree-dependent evidence true. A sibling worktree with
// matching content, another repo, or an unknown cwd all adopt degraded.

const { toWindowsPath } = require("../../lib/branch-diff");
const { GRANULARITY_FULL, GRANULARITY_CONTEXT_INDEPENDENT_ONLY } = require("./apply");

// Looked up per call, not destructured at load, so the owner module stays the
// one place every consumer reaches (tests swap its cache entry).
const repoIdentity = () => require("../../lib/repo-identity");

// state.cwd is the projected cwd (worktree transitions move it); the start
// context is the immutable fallback.
function upstreamCwdOf(state) {
  if (!state || typeof state !== "object") return null;
  // state.cwd stays on main when the worktree was started mid-session; /resume-session sends the
  // downstream into the live linked session_worktree, so that is the checkout compared against.
  // Same candidate order as bin/lib/resume-session/upstream-cwd.js: cwd first, then session_worktree.
  for (const c of [state.cwd, state.session_worktree]) {
    if (typeof c !== "string" || !c.length) continue;
    try {
      const p = toWindowsPath(c);
      if (require("../resolve-worktree-path").isOwnedLinkedWorktree(p)) return c;
    } catch (_) { /* try the next candidate */ }
  }
  if (typeof state.cwd === "string" && state.cwd.length) return state.cwd;
  const ctx = state.session_start_context;
  return ctx && typeof ctx.cwd === "string" && ctx.cwd.length ? ctx.cwd : null;
}

// judgeInheritanceGranularity(downstreamCwd, upstreamState, ri?) -> { granularity, repo_verdict }
// ri: the caller's own hooks/lib/repo-identity handle; defaults to a per-call lookup.
function judgeInheritanceGranularity(downstreamCwd, upstreamState, ri = repoIdentity()) {
  const upCwd = upstreamCwdOf(upstreamState);
  const known = typeof downstreamCwd === "string" && downstreamCwd.length > 0 && upCwd !== null;
  const verdict = known
    ? ri.compareRepoIdentity(toWindowsPath(downstreamCwd), toWindowsPath(upCwd))
    : ri.VERDICTS.UNKNOWN;
  return {
    granularity: verdict === ri.VERDICTS.SAME ? GRANULARITY_FULL : GRANULARITY_CONTEXT_INDEPENDENT_ONLY,
    repo_verdict: verdict,
  };
}

function decideInheritanceGranularity(downstreamCwd, upstreamState) {
  return judgeInheritanceGranularity(downstreamCwd, upstreamState).granularity;
}

module.exports = { decideInheritanceGranularity, judgeInheritanceGranularity, upstreamCwdOf };
