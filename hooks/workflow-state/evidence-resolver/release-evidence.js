"use strict";
// Completion evidence for the release steps push_branch / deliver (#2527 3-3).
// Every predicate fails to false: an UNKNOWN forge answer, a timeout, or a git
// error leaves the step pending, and the idempotent skill re-checks the real
// state. No predicate fetches; the remote-tracking refs are taken as recorded.

const { spawnSync } = require("child_process");

const RELEASE_EVIDENCE_STEPS = Object.freeze(["push_branch", "deliver"]);

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

function hasReleaseEvidence(step, sessionId, opts) {
  const repoDir = opts && opts.repoDir;
  if (!repoDir) return false;
  const deliveryPath = deliveryPathOf(sessionId, opts || {});
  const { prStateForBranch } = require("../../workflow-gate/gh-detect");
  if (step === "push_branch") {
    if (deliveryPath !== "pull_request") return false;
    const state = prStateForBranch(repoDir);
    return state === "OPEN" || state === "MERGED";
  }
  if (step === "deliver") {
    if (deliveryPath === "pull_request") return prStateForBranch(repoDir) === "MERGED";
    if (deliveryPath === "direct") return isDirectDelivered(repoDir);
  }
  return false;
}

function describeReleaseEvidence(step) {
  if (step === "push_branch") {
    return [
      "pull_request path: the current branch's PR state (prStateForBranch) is OPEN or MERGED",
      "direct path: no evidence (the step table skips push_branch there)",
      "queried only for the evaluated step of next-step's verdict (evidencePolicy.network)",
    ];
  }
  if (step === "deliver") {
    return [
      "pull_request path: the current branch's PR state (prStateForBranch) is MERGED",
      "direct path: the default branch is checked out, `git status --porcelain` is empty (untracked "
        + "included), and HEAD equals origin/<default> (not ahead, not diverged; no fetch)",
      "queried only for the evaluated step of next-step's verdict (evidencePolicy.network)",
    ];
  }
  return [];
}

module.exports = { RELEASE_EVIDENCE_STEPS, hasReleaseEvidence, describeReleaseEvidence, isDirectDelivered };
