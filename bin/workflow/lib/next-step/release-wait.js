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

// The poller (skills/get-release-approval/scripts/wait-web-merge.sh) touches its pid file on
// every poll; its longest sleep is 300 s, so an older file is a poller that died.
const POLLER_STALE_MS = 11 * 60 * 1000;

// pollerIsWaiting(sid) -> true only while a background poller of this session is polling.
// WAIT (which lets the turn end) is announced only then: without a poller nothing would
// notice the web merge, so the skill that starts it must still be invoked.
function pollerIsWaiting(sid) {
  try {
    const { getStateRoot } = require("../../../../hooks/workflow-state/state-io/state-root");
    const file = require("path").join(getStateRoot(), "web-merge-poller-" + sid + ".pid");
    const st = require("fs").statSync(file);
    return st.size > 0 && Date.now() - st.mtimeMs < POLLER_STALE_MS;
  } catch (e) {
    return false;
  }
}

function releaseWaitVerdict(ctx) {
  const { state, sid, repoDir, profile, forgeMemo } = ctx || {};
  if (!repoDir || releaseApprovalChannelOf(state, profile) !== "web-merge") return null;
  const pr = ms.memoizedMergeStateForBranch(repoDir, { forgeMemo, timeoutMs: ms.FORGE_QUERY_TIMEOUT_MS });
  const prState = pr && pr.state;
  if (prState === "OPEN" && pr.mergeState === "CLEAN") {
    return {
      action: "invoke", skill: SKILL, reason: "web-merge-pending",
      wait: sid && pollerIsWaiting(sid) ? "human-web-merge" : "",
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
