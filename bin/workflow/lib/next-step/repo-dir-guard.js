"use strict";
// Does the repoDir this process resolved actually belong to the session being
// evaluated? next-step resolves repoDir from the CALLING process, so a
// cross-session `--session <other-sid>` would otherwise grade another session's
// workflow against this worktree's evidence.
//
// Shared, because two call sites need the same comparison with DIFFERENT
// consequences: verdict.js fails fast, resume-session's upstream view degrades
// inheritance granularity instead.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { readState } = require("../../../../hooks/workflow-state/state-io");

const VERDICTS = Object.freeze({
  SAME: "same",
  SIBLING: "sibling-worktree",
  DIFFERENT: "different-repo",
  UNKNOWN: "unknown",
  INDETERMINATE: "indeterminate",
});

// Lexical form only: drive-letter spellings (`/C/x`, `c:/x`, `C:\x`), trailing
// separators and case differences are the same path, and samePath() in
// inheritance/context-match.js misses all three.
function normalizePathForCompare(value) {
  if (typeof value !== "string" || value.length === 0) return null;
  let out = value.trim();
  if (out.length === 0) return null;
  out = out.replace(/\\/g, "/");
  const posixDrive = /^\/([A-Za-z])\//.exec(out);
  if (posixDrive) out = posixDrive[1] + ":/" + out.slice(3);
  out = out.replace(/\/+$/, "");
  return out.toLowerCase();
}

function git(dir, args) {
  try {
    const r = spawnSync("git", ["-C", dir].concat(args), {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (!r || r.error || r.status !== 0) return null;
    return String(r.stdout || "").trim();
  } catch (e) {
    return null;
  }
}

function compareRepoIdentity(recordedCwd, repoDir) {
  const a = normalizePathForCompare(recordedCwd);
  const b = normalizePathForCompare(repoDir);
  if (a === null) return VERDICTS.UNKNOWN;
  if (b === null) return VERDICTS.UNKNOWN;
  if (a === b) return VERDICTS.SAME;

  const topA = git(recordedCwd, ["rev-parse", "--show-toplevel"]);
  const topB = git(repoDir, ["rev-parse", "--show-toplevel"]);
  if (topA === null || topB === null) return VERDICTS.INDETERMINATE;
  if (normalizePathForCompare(topA) === normalizePathForCompare(topB)) return VERDICTS.SAME;

  const commonA = git(recordedCwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  const commonB = git(repoDir, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  if (commonA === null || commonB === null) return VERDICTS.INDETERMINATE;
  if (normalizePathForCompare(commonA) === normalizePathForCompare(commonB)) return VERDICTS.SIBLING;
  return VERDICTS.DIFFERENT;
}

// Two-valued on purpose: "cannot tell" is not equivalence, so a spawn failure
// lands on false rather than inventing a third outcome.
function compareRepoContentEquivalence(dirA, dirB) {
  const headA = git(dirA, ["rev-parse", "HEAD"]);
  const headB = git(dirB, ["rev-parse", "HEAD"]);
  if (headA === null || headB === null) return false;
  // HEAD equality is the floor for EVERY branch, dirty or clean: two trees on
  // divergent commits carrying the same uncommitted diff are not equivalent.
  if (headA !== headB) return false;
  const statusA = git(dirA, ["status", "--porcelain"]);
  const statusB = git(dirB, ["status", "--porcelain"]);
  if (statusA === null || statusB === null) return false;
  if (statusA.length === 0 && statusB.length === 0) return true;
  // A dirty tree is what the session actually holds, so on a shared HEAD the
  // working-tree diff is the remaining fact that decides equivalence.
  const diffA = git(dirA, ["diff", "HEAD"]);
  const diffB = git(dirB, ["diff", "HEAD"]);
  if (diffA === null || diffB === null) return false;
  if (diffA !== diffB) return false;
  // `git diff HEAD` is blind to untracked files, so a tracked-diff match alone
  // would call two trees equivalent while one carries files the other lacks.
  return untrackedContentMatches(dirA, dirB);
}

function untrackedPaths(dir) {
  const out = git(dir, ["ls-files", "--others", "--exclude-standard"]);
  if (out === null) return null;
  return out.split(/\r?\n/).filter((p) => p.length > 0).sort();
}

const MAX_UNTRACKED_COMPARE_BYTES = 1024 * 1024;

// lstat, never stat: a symlink is compared as a link, so following it into an
// arbitrary target can never make two trees look equivalent. The size cap keeps
// an untracked multi-gigabyte blob from being read into memory to prove it.
function untrackedFileEquals(fileA, fileB) {
  const statA = fs.lstatSync(fileA);
  const statB = fs.lstatSync(fileB);
  if (!statA.isFile() || !statB.isFile()) return false;
  if (statA.size !== statB.size) return false;
  if (statA.size > MAX_UNTRACKED_COMPARE_BYTES) return false;
  return fs.readFileSync(fileA).equals(fs.readFileSync(fileB));
}

function untrackedContentMatches(dirA, dirB) {
  const pathsA = untrackedPaths(dirA);
  const pathsB = untrackedPaths(dirB);
  if (pathsA === null || pathsB === null) return false;
  if (pathsA.length !== pathsB.length) return false;
  for (let i = 0; i < pathsA.length; i += 1) {
    if (pathsA[i] !== pathsB[i]) return false;
  }
  for (const rel of pathsA) {
    try {
      if (!untrackedFileEquals(path.join(dirA, rel), path.join(dirB, rel))) return false;
    } catch (e) {
      return false;
    }
  }
  return true;
}

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

  return { ok: false, verdict, verifiedEquivalent: false, reason: verdict };
}

module.exports = {
  VERDICTS,
  normalizePathForCompare,
  compareRepoIdentity,
  compareRepoContentEquivalence,
  assertRepoDirMatchesSession,
};
