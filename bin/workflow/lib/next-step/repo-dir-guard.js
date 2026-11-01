"use strict";
// Does the repoDir this process resolved actually belong to the session being
// evaluated? next-step resolves repoDir from the CALLING process, so a
// cross-session `--session <other-sid>` would otherwise grade another session's
// workflow against this worktree's evidence.
//
// The repo-identity comparator itself lives in hooks/lib/repo-identity.js and is
// re-exported here unchanged for existing callers.

const fs = require("fs");
const { readState } = require("../../../../hooks/workflow-state/state-io");
const { toWindowsPath } = require("../../../../hooks/lib/branch-diff");
const {
  VERDICTS,
  normalizePathForCompare,
  compareRepoIdentity,
  compareRepoContentEquivalence,
} = require("../../../../hooks/lib/repo-identity");

function recordedCwdFor(sid) {
  let state;
  try {
    state = readState(sid);
  } catch (e) {
    return null;
  }
  if (!state) return null;
  // state.cwd is the PROJECTED cwd (worktree transitions update it); the
  // session_start_context copy is the immutable start value, so it is the fallback.
  if (typeof state.cwd === "string" && state.cwd.length) return state.cwd;
  const ctx = state.session_start_context;
  if (ctx && typeof ctx.cwd === "string" && ctx.cwd.length) return ctx.cwd;
  return null;
}

// Returns {ok, verdict, verifiedEquivalent, reason}. ok:false means the caller
// must stop; it never throws, so each call site chooses its own consequence.
function assertRepoDirMatchesSession(sid, repoDir, opts) {
  const options = opts && typeof opts === "object" ? opts : {};
  const isExplicitSessionOverride = options.isExplicitSessionOverride === true;
  const recordedCwd = recordedCwdFor(sid);
  const verdict = compareRepoIdentity(recordedCwd, repoDir);

  if (verdict === VERDICTS.SAME) return { ok: true, verdict, verifiedEquivalent: false };

  if (verdict === VERDICTS.SIBLING) {
    // Fail-open for a self-call: the session's own worktree legitimately
    // diverges from wherever it was recorded at session start (e.g. it
    // started in the main checkout, then /worktree-start created and entered
    // a linked worktree) — that is the normal shape of every worktree-based
    // session, not a mismatch. Only a cross-session call needs the stronger
    // content-equivalence proof before continuing.
    if (!isExplicitSessionOverride) {
      return { ok: true, verdict, verifiedEquivalent: false };
    }
    const equivalent = compareRepoContentEquivalence(recordedCwd, repoDir);
    if (equivalent) return { ok: true, verdict, verifiedEquivalent: true };
    return { ok: false, verdict, verifiedEquivalent: false, reason: "sibling-worktree-content-diverged" };
  }

  if (verdict === VERDICTS.UNKNOWN) {
    // Always fail-open: UNKNOWN means no recorded cwd exists to compare
    // against — a migration-period gap of the new session_start_context.cwd
    // field, never evidence of a cross-session call. isExplicitSessionOverride
    // is a bare sid inequality, too unreliable to fail closed on by itself.
    process.stderr.write(
      `repo-context-unverified: session ${sid} recorded no cwd, so ${repoDir} cannot be confirmed as its repo\n`
    );
    return { ok: true, verdict, verifiedEquivalent: false, reason: "repo-context-unverified" };
  }

  if (
    verdict === VERDICTS.INDETERMINATE &&
    !isExplicitSessionOverride &&
    typeof recordedCwd === "string" &&
    !fs.existsSync(toWindowsPath(recordedCwd))
  ) {
    // #2316: a deleted worktree (e.g. after /worktree-end) leaves a recorded cwd
    // git can no longer describe → INDETERMINATE. Fail open ONLY for a self-call
    // whose recorded path is gone from disk — symmetric to UNKNOWN and to the
    // SIBLING branch above. A cross-session override never earns the deleted-path
    // pass (#2319: it would let another worktree grade this session), and an
    // INDETERMINATE where the path still exists (R4 broken-git) stays fail-fast.
    process.stderr.write(
      `repo-context-worktree-deleted: session ${sid} recorded cwd ${recordedCwd} no longer exists; failing open\n`
    );
    return { ok: true, verdict, verifiedEquivalent: false, reason: "repo-context-worktree-deleted" };
  }

  if (verdict === VERDICTS.INDETERMINATE && !isExplicitSessionOverride && isOwnedLeftoverOfRepo(sid, recordedCwd, repoDir)) {
    // #2875: a WE-11 failure leaves the recorded worktree on disk with a pruned gitlink. Fail open
    // only for a self-call on an unregistered leftover of THIS repo that the session owned.
    process.stderr.write(
      `repo-context-worktree-leftover: session ${sid} recorded cwd ${recordedCwd} is an unregistered worktree leftover; failing open\n`
    );
    return { ok: true, verdict, verifiedEquivalent: false, reason: "repo-context-worktree-leftover" };
  }

  return { ok: false, verdict, verifiedEquivalent: false, reason: verdict };
}

function isOwnedLeftoverOfRepo(sid, recordedCwd, repoDir) {
  try {
    if (typeof recordedCwd !== "string" || !fs.existsSync(toWindowsPath(recordedCwd))) return false;
    const { classifyWorktreeLeftover, gitCommonDirOf } = require("../../../../hooks/workflow-state/resolve-worktree-path");
    const leftover = classifyWorktreeLeftover(recordedCwd);
    if (leftover.kind !== "unregistered-leftover") return false;
    const repoCommon = gitCommonDirOf(toWindowsPath(repoDir));
    const same = (a, b) => normalizePathForCompare(a) !== null && normalizePathForCompare(a) === normalizePathForCompare(b);
    if (!repoCommon || !same(leftover.commonDir, repoCommon)) return false;
    const state = readState(sid);
    if (!state) return false;
    return same(state.session_worktree, recordedCwd) || !!state.worktree_entered_at;
  } catch (_e) {
    return false;
  }
}

module.exports = {
  VERDICTS,
  normalizePathForCompare,
  compareRepoIdentity,
  compareRepoContentEquivalence,
  assertRepoDirMatchesSession,
};
