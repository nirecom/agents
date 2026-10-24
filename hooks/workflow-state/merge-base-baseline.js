"use strict";
// The session's merge-base baseline: WHERE THIS BRANCH STARTED, recorded as a fact.
// INVARIANT: exactly ONE automatic writer (hooks/workflow-mark/branching-handler.js, on
// BRANCHING_COMPLETE, write-once) and exactly ONE override (approveMergeBaseBaseline(), only via
// bin/workflow/record-merge-base-baseline after the user confirmed the base — the ONLY path that
// may replace a record). Any third writer turns the baseline back into a guess (#1638).
// `base` is `git rev-parse HEAD` at branching time, UNCONDITIONALLY — never a merge-base against
// a remote branch, the stale value #1638 was caused by.
// `post_session_head` / `alt_base` are EVIDENCE, never decisions: a consumer may say "the
// recorded base may be behind your HEAD, here is the alternative", but no code silently
// switches to it.

const { spawnSync } = require("../lib/limited-child-process");
const { readState, writeState, createInitialState } = require("./state-io");

// Git Bash hands out MSYS drive-letter paths; spawnSync on Windows must be given the Windows form instead.
// Same normalization as hooks/enforce-worktree/git-repo-detection.js.
function toWindowsPath(raw) {
  if (!raw) return raw;
  const driveMatch = raw.match(/^\/([a-zA-Z])(\/.*)?$/);
  if (driveMatch) {
    return driveMatch[1].toUpperCase() + ":\\" +
      (driveMatch[2] || "").replace(/\//g, "\\").replace(/^\\/, "");
  }
  if (process.platform === "win32" && /^[a-zA-Z]:\//.test(raw)) return raw.replace(/\//g, "\\");
  return raw;
}

// One git call. Arguments are passed as an argv array with no shell, so a repo path or a sha
// carrying shell metacharacters is data and never a command.
function git(repoRoot, args) {
  const r = spawnSync("git", ["-C", toWindowsPath(repoRoot), ...args], {
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (r.error || r.status !== 0) return null;
  return typeof r.stdout === "string" ? r.stdout.trim() : "";
}

function gitOk(repoRoot, args) {
  const r = spawnSync("git", ["-C", toWindowsPath(repoRoot), ...args], {
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return !r.error && r.status === 0;
}

// resolveBaselineForRepo(repoRoot, sessionCreatedAt):
// Measures the repository. Returns null when repoRoot is not a usable git repository — the
// caller degrades to guessing, it does not fail.
function resolveBaselineForRepo(repoRoot, sessionCreatedAt) {
  if (typeof repoRoot !== "string" || !repoRoot) return null;
  const head = git(repoRoot, ["rev-parse", "HEAD"]);
  if (!head || !/^[0-9a-f]{40}$/.test(head)) return null;

  let branch = git(repoRoot, ["rev-parse", "--abbrev-ref", "HEAD"]);
  if (!branch || branch === "HEAD") branch = null;

  const headCommittedAt = git(repoRoot, ["log", "-1", "--format=%cI", "HEAD"]) || null;

  let postSessionHead = false;
  if (headCommittedAt && sessionCreatedAt) {
    const h = Date.parse(headCommittedAt);
    const s = Date.parse(sessionCreatedAt);
    if (!Number.isNaN(h) && !Number.isNaN(s)) postSessionHead = h > s;
  }

  // Local refs only — no fetch. Informational: nothing ever adopts alt_base automatically.
  const altBase =
    git(repoRoot, ["merge-base", "origin/main", "HEAD"]) ||
    git(repoRoot, ["merge-base", "main", "HEAD"]) ||
    null;

  return {
    base: head,
    branch,
    branch_head: head,
    head_committed_at: headCommittedAt,
    post_session_head: postSessionHead,
    alt_base: altBase || null,
  };
}

function loadOrCreate(sessionId) {
  const state = readState(sessionId);
  if (state) return state;
  return createInitialState(sessionId);
}

// recordMergeBaseBaseline(sessionId, repoRoot):
// The automatic path. Write-once, on the recordSessionModel precedent: a re-emitted
// BRANCHING_COMPLETE must not move a base that later gates have already scoped themselves by.
// Never throws — a lost baseline degrades to guessing, it must never abort the caller's step.
function recordMergeBaseBaseline(sessionId, repoRoot) {
  try {
    const state = loadOrCreate(sessionId);
    if (state.merge_base_baseline) {
      return { recorded: false, reason: "a merge-base baseline is already recorded (write-once)" };
    }
    const measured = resolveBaselineForRepo(repoRoot, state.created_at);
    if (!measured) {
      return { recorded: false, reason: `merge-base baseline: ${repoRoot} is not a usable git repository` };
    }
    state.merge_base_baseline = {
      recorded_at: new Date().toISOString(),
      base: measured.base,
      branch: measured.branch,
      branch_head: measured.branch_head,
      repo_root: repoRoot,
      source: "recorded-baseline",
      head_committed_at: measured.head_committed_at,
      session_created_at: state.created_at || null,
      post_session_head: measured.post_session_head,
      alt_base: measured.alt_base,
      approved_reason: null,
    };
    writeState(sessionId, state);
    return { recorded: true, reason: `merge-base baseline recorded: ${measured.base}` };
  } catch (e) {
    return { recorded: false, reason: `merge-base baseline: ${e.message}` };
  }
}

// approveMergeBaseBaseline(sessionId, repoRoot, base, reason):
// The ONLY write-once-breaking path, and the reason it is safe to break it: the value came
// from the user, not from a heuristic. Validation is what keeps a sha that does not resolve —
// or one that is not on this branch — out of the state file, so a refusal must leave whatever
// was already stored exactly as it was.
//
// A write that FAILS propagates: claiming success for an override the user asked for would be
// worse than an error they can see.
function approveMergeBaseBaseline(sessionId, repoRoot, base, reason) {
  if (typeof reason !== "string" || reason.trim() === "") {
    return { recorded: false, reason: "--reason is mandatory: the override is an audited decision" };
  }
  if (typeof base !== "string" || base.trim() === "") {
    return { recorded: false, reason: "--base is mandatory" };
  }
  const wanted = base.trim();
  const resolved = git(repoRoot, ["rev-parse", "--verify", `${wanted}^{commit}`]);
  if (!resolved || !/^[0-9a-f]{40}$/.test(resolved)) {
    return { recorded: false, reason: `base does not resolve to a commit in ${repoRoot}: ${wanted}` };
  }
  if (!gitOk(repoRoot, ["merge-base", "--is-ancestor", resolved, "HEAD"])) {
    return { recorded: false, reason: `base is not an ancestor of HEAD: ${wanted}` };
  }

  const measured = resolveBaselineForRepo(repoRoot, null);
  if (!measured) {
    return { recorded: false, reason: `${repoRoot} is not a usable git repository` };
  }

  const state = loadOrCreate(sessionId);
  const previous = state.merge_base_baseline || {};
  state.merge_base_baseline = {
    recorded_at: new Date().toISOString(),
    base: resolved,
    branch: measured.branch,
    branch_head: measured.branch_head,
    repo_root: repoRoot,
    source: "user-approved",
    head_committed_at: measured.head_committed_at,
    session_created_at: previous.session_created_at || state.created_at || null,
    post_session_head: false,
    alt_base: previous.base && previous.base !== resolved ? previous.base : measured.alt_base,
    approved_reason: reason,
  };
  writeState(sessionId, state);
  return { recorded: true, base: resolved, reason: `merge-base baseline approved: ${resolved}` };
}

// readMergeBaseBaseline(sessionId): the stored record, or null. Fail-open like readState —
// an unreadable or corrupt state file is "no baseline", not an error.
function readMergeBaseBaseline(sessionId) {
  try {
    const state = readState(sessionId);
    if (!state || !state.merge_base_baseline) return null;
    return state.merge_base_baseline;
  } catch (e) {
    return null;
  }
}

module.exports = {
  resolveBaselineForRepo,
  recordMergeBaseBaseline,
  approveMergeBaseBaseline,
  readMergeBaseBaseline,
};
