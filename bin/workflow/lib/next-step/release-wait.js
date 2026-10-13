"use strict";
// next-step's user_verification verdict on the web-merge channel (#2527 4-4): the human merges
// the PR on the web, so the verdict follows the PR, read once per run through the forge memo.
// null → not the web-merge channel, or nothing to say (MERGED settles via evidence; NONE falls
// back to /get-release-approval, whose preflight names the missing PR). No single quotes:
// emit() wraps NEXT_HINT / REASON in them.

const { releaseApprovalChannelOf } = require("../../../../hooks/workflow-state/session-profile");
const ms = require("../../../../hooks/lib/forge/merge-state");
const { STEP_TO_SKILL } = require("./steps");

const SKILL = STEP_TO_SKILL.user_verification || "get-release-approval";

function prLabel(pr) {
  return pr.number ? "PR #" + pr.number : "The PR";
}

function releaseWaitVerdict(ctx) {
  const { state, repoDir, profile, forgeMemo } = ctx || {};
  if (!repoDir || releaseApprovalChannelOf(state, profile) !== "web-merge") return null;
  const pr = ms.memoizedMergeStateForBranch(repoDir, { forgeMemo, timeoutMs: ms.FORGE_QUERY_TIMEOUT_MS });
  const prState = pr && pr.state;
  if (prState === "OPEN" && pr.mergeState === "CLEAN") {
    return {
      action: "invoke", skill: SKILL, reason: "web-merge-pending", wait: "human-web-merge",
      hint: prLabel(pr) + " is ready; the human merges it on the web (" + (pr.url || "no URL") +
        "); run /get-release-approval to start the background poller",
    };
  }
  if (prState === "OPEN") {
    return {
      action: "invoke", skill: SKILL, reason: "web-merge-not-ready", wait: "",
      hint: prLabel(pr) + " is open but not ready to merge (" + (pr.mergeState || "UNKNOWN") +
        "); run /get-release-approval",
    };
  }
  if (prState === "CLOSED") {
    return {
      action: "blocked", skill: "", reason: "web-merge-closed", wait: "",
      hint: "PR was closed without merge; reopen or re-run /commit-push",
    };
  }
  if (prState === "MERGED" || prState === "NONE") return null;
  return {
    action: "blocked", skill: "", reason: "web-merge-pr-unreadable", wait: "",
    hint: "cannot read PR state; check gh auth / network and re-run /get-release-approval",
  };
}

module.exports = { releaseWaitVerdict };
