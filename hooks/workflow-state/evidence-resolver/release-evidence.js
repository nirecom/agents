"use strict";
// Completion evidence for the release steps push_branch / merge_to_main (#2527 3-3).
// Every predicate fails to false: an UNKNOWN forge answer, a timeout, or a git
// error leaves the step pending, and the idempotent skill re-checks the real
// state. No predicate fetches; the remote-tracking refs are taken as recorded.

const { spawnSync } = require("../../lib/limited-child-process");

// user_verification (#2527 4-4): on the web-merge channel the human's merge on the web IS the
// release approval; the dialog channel has no evidence (the USER_VERIFIED dialog records it).
const RELEASE_EVIDENCE_STEPS = Object.freeze(["push_branch", "user_verification", "merge_to_main"]);

function git(repoDir, args) {
  const r = spawnSync("git", ["-C", repoDir].concat(args), { encoding: "utf8", timeout: 5000 });
  if (!r || r.error || r.status !== 0) return null;
  return (r.stdout || "").trim();
}

function deliveryPathOf(sessionId, opts) {
  const { readState } = require("../state-io");
  const { resolveSessionProfile } = require("../session-profile");
  const state = opts.state || (sessionId ? readState(sessionId) : null);
  return resolveSessionProfile(state, sessionId, { repoDir: opts.repoDir }).deliveryPath;
}

// Direct delivery is done when the default branch is checked out, the tree is
// clean (untracked included), and HEAD is exactly the remote-tracking tip — so
// neither an unpushed nor a diverged history counts.
function isDirectDelivered(repoDir) {
  const { getProtectedBranches } = require("../../lib/merge-detect");
  const branch = git(repoDir, ["rev-parse", "--abbrev-ref", "HEAD"]);
  if (!branch || getProtectedBranches().indexOf(branch) === -1) return false;
  const status = git(repoDir, ["status", "--porcelain", "--untracked-files=all"]);
  if (status === null || status !== "") return false;
  const remoteRef = "refs/remotes/origin/" + branch;
  const ahead = git(repoDir, ["rev-list", "--count", remoteRef + "..HEAD"]);
  if (ahead === null || ahead !== "0") return false;
  const head = git(repoDir, ["rev-parse", "HEAD"]);
  const remote = git(repoDir, ["rev-parse", "--verify", remoteRef]);
  return !!head && head === remote;
}

// prStateOf(repoDir, opts) — this run's memoized forge answer when one exists (opts.forgeMemo,
// filled by mergeStateForBranch), else a fresh prForBranch read bounded by the next-step budget.
// Both carry the head-commit check: OPEN / MERGED is never the answer for another commit's PR.
function prStateOf(repoDir, opts) {
  const ms = require("../../lib/forge/merge-state");
  const cached = ms.cachedMergeState(repoDir, opts && opts.forgeMemo);
  if (cached) return cached.state;
  const { prForBranch } = require("../../workflow-gate/gh-detect");
  return prForBranch(repoDir, { timeoutMs: ms.FORGE_QUERY_TIMEOUT_MS }).state;
}

function hasReleaseEvidence(step, sessionId, opts) {
  const o = opts || {};
  const repoDir = o.repoDir;
  if (!repoDir) return false;
  if (step === "user_verification") {
    const { readState } = require("../state-io");
    const state = o.state || (sessionId ? readState(sessionId) : null);
    return require("../release-approval").isWebMergeObserved(state, sessionId, o);
  }
  const deliveryPath = deliveryPathOf(sessionId, o);
  if (step === "push_branch") {
    if (deliveryPath !== "pull_request") return false;
    const state = prStateOf(repoDir, o);
    return state === "OPEN" || state === "MERGED";
  }
  if (step === "merge_to_main") {
    if (deliveryPath === "pull_request") return prStateOf(repoDir, o) === "MERGED";
    if (deliveryPath === "direct") return isDirectDelivered(repoDir);
  }
  return false;
}

function describeReleaseEvidence(step) {
  if (step === "push_branch") {
    return [
      "pull_request path: the current branch's PR state (prForBranch) is OPEN or MERGED "
        + "with the PR's head commit equal to the local HEAD",
      "direct path: no evidence (the step table skips push_branch there)",
      "queried only for the evaluated step of next-step's verdict (evidencePolicy.network)",
    ];
  }
  if (step === "user_verification") {
    return [
      "web-merge channel (pull_request + AUTO_MERGE_PR=off fixed at branching): the current branch's "
        + "PR state (mergeStateForBranch) is MERGED with the PR's head commit equal to the local HEAD "
        + "— the human's web merge is the release approval",
      "user-verified-dialog channel: no evidence (no forge query); the USER_VERIFIED dialog records it",
      "queried only for the evaluated step of next-step's verdict (evidencePolicy.network)",
    ];
  }
  if (step === "merge_to_main") {
    return [
      "pull_request path: the current branch's PR state (prForBranch) is MERGED with the "
        + "PR's head commit equal to the local HEAD",
      "direct path: the default branch is checked out, `git status --porcelain` is empty (untracked "
        + "included), and HEAD equals origin/<default> (not ahead, not diverged; no fetch)",
      "queried only for the evaluated step of next-step's verdict (evidencePolicy.network)",
    ];
  }
  return [];
}

module.exports = { RELEASE_EVIDENCE_STEPS, hasReleaseEvidence, describeReleaseEvidence, isDirectDelivered };
