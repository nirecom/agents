"use strict";
// Release approval (#2527 4-4): the one predicate for "the human approved this release".
// Channel SSOT: session-profile.js releaseApprovalChannelOf. Never throws; a failed read is false.

const { isDeliveryBoundaryReset } = require("./effective-state/delivery-boundary");

function profileOf(state, sessionId, opts) {
  if (opts && opts.profile) return opts.profile;
  const { resolveSessionProfile } = require("./session-profile");
  return resolveSessionProfile(state, sessionId, { repoDir: opts && opts.repoDir });
}

function channelOf(state, sessionId, opts) {
  const { releaseApprovalChannelOf } = require("./session-profile");
  return releaseApprovalChannelOf(state, profileOf(state, sessionId, opts));
}

// isWebMergeObserved — web-merge channel only: the PR is MERGED (one memoized forge read per
// run via opts.forgeMemo). The dialog channel answers false without touching the forge.
function isWebMergeObserved(state, sessionId, opts) {
  try {
    const o = opts || {};
    if (!o.repoDir || channelOf(state, sessionId, o) !== "web-merge") return false;
    const ms = require("../lib/forge/merge-state");
    const pr = ms.memoizedMergeStateForBranch(o.repoDir, {
      forgeMemo: o.forgeMemo, timeoutMs: ms.FORGE_QUERY_TIMEOUT_MS,
    });
    return !!pr && pr.state === "MERGED";
  } catch (_) {
    return false;
  }
}

// isReleaseApprovalSatisfied — the recorded USER_VERIFIED approval, a dialog-channel delivery
// boundary reset (the approved delivery already happened), or an observed web merge.
function isReleaseApprovalSatisfied(state, sessionId, opts) {
  try {
    const uv = state && state.steps && state.steps.user_verification;
    if (uv && uv.status === "complete") return true;
    const o = opts || {};
    const channel = channelOf(state, sessionId, o);
    if (channel !== "web-merge") return isDeliveryBoundaryReset(uv);
    return isWebMergeObserved(state, sessionId, o);
  } catch (_) {
    return false;
  }
}

module.exports = { isReleaseApprovalSatisfied, isWebMergeObserved };
