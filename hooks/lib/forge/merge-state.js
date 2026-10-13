"use strict";
// One-query PR/MR merge readiness { state, number, mergeState, url, error } (#2527 4-5);
// owns the GitLab detailed_merge_status -> gh mergeStateStatus mapping (SSOT).
// Per-forge spawns live on each codehost descriptor (mergeStateForBranch).

// A forge read made inside next-step must leave the Stop guard's 5000ms budget room.
const FORGE_QUERY_TIMEOUT_MS = 3000;

const GITLAB_MERGE_STATUS_MAP = Object.freeze({
  mergeable: "CLEAN", can_be_merged: "CLEAN",
  conflict: "DIRTY", cannot_be_merged: "DIRTY",
  need_rebase: "BEHIND",
  draft_status: "DRAFT",
  ci_must_pass: "BLOCKED", ci_still_running: "BLOCKED", not_approved: "BLOCKED",
  discussions_not_resolved: "BLOCKED", blocked_status: "BLOCKED", external_status_checks: "BLOCKED",
  jira_association_missing: "BLOCKED", requested_changes: "BLOCKED",
});

// gitlabMergeState(mr) -> gh-vocabulary merge state of a glab MR JSON object. A draft flag
// wins; an uncomputed status (checking / unchecked / preparing) passes through uppercased.
function gitlabMergeState(mr) {
  if (!mr || typeof mr !== "object") return "";
  if (mr.draft === true || mr.work_in_progress === true) return "DRAFT";
  const raw = String(mr.detailed_merge_status || mr.merge_status || "");
  return GITLAB_MERGE_STATUS_MAP[raw] || raw.toUpperCase();
}

function unknownMergeState(error) {
  return { state: "UNKNOWN", number: "", mergeState: "", url: "", error: String(error || "unknown forge failure") };
}

// spawnFailure(r, cli, timeoutMs) -> a one-line reason for a spawn that never produced an exit.
function spawnFailure(r, cli, timeoutMs) {
  const e = r && r.error;
  if (!e) return "";
  if (e.code === "ETIMEDOUT") return `${cli} timed out after ${timeoutMs}ms`;
  if (e.code === "ENOENT") return `${cli} not found (or the repository directory does not exist)`;
  return `${cli} failed to start: ${e.message || e.code || "unknown"}`;
}

function timeoutOf(opts) {
  const t = opts && Number(opts.timeoutMs);
  return Number.isFinite(t) && t > 0 ? t : FORGE_QUERY_TIMEOUT_MS;
}

// mergeStateForBranch(repoDir, { timeoutMs }) -> never throws; an unreadable origin or an
// unknown host is UNKNOWN with no forge call.
function mergeStateForBranch(repoDir, opts) {
  try {
    const { originUrl } = require("../../workflow-gate/gh-detect");
    const url = originUrl(repoDir);
    if (!url) return unknownMergeState("no origin remote readable in " + repoDir);
    const descriptor = require("../forge-router").resolveCodehostDescriptor(url);
    if (!descriptor || typeof descriptor.mergeStateForBranch !== "function") {
      return unknownMergeState("no forge handler for the origin host");
    }
    return descriptor.mergeStateForBranch(repoDir, { timeoutMs: timeoutOf(opts) });
  } catch (e) {
    return unknownMergeState(e && e.message);
  }
}

// createForgeMemo() -> a per-run memo (one forge query per repoDir per next-step run).
function createForgeMemo() {
  return new Map();
}

// memoizedMergeStateForBranch(repoDir, { forgeMemo, timeoutMs }) — answered from the memo
// when this run already asked; without a memo, a fresh query.
function memoizedMergeStateForBranch(repoDir, opts) {
  const memo = opts && opts.forgeMemo;
  if (!(memo instanceof Map)) return mergeStateForBranch(repoDir, opts);
  const key = String(repoDir || "");
  if (!memo.has(key)) memo.set(key, mergeStateForBranch(repoDir, opts));
  return memo.get(key);
}

// cachedMergeState(repoDir, forgeMemo) -> the memoized answer, or null when this run never asked.
function cachedMergeState(repoDir, forgeMemo) {
  if (!(forgeMemo instanceof Map)) return null;
  return forgeMemo.get(String(repoDir || "")) || null;
}

module.exports = {
  FORGE_QUERY_TIMEOUT_MS,
  GITLAB_MERGE_STATUS_MAP,
  gitlabMergeState,
  unknownMergeState,
  spawnFailure,
  mergeStateForBranch,
  createForgeMemo,
  memoizedMergeStateForBranch,
  cachedMergeState,
};
