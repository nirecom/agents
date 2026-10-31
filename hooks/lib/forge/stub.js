"use strict";

// No-op forge descriptors (#2307). A codehost/tracker that has no real handler
// resolves here instead of silently reusing GitHub's — the security invariant is
// "no fallback". Each method's return value is the fail-safe for its axis.
const codehostStub = {
  isPrivateRepo(_remoteUrl) { return false; },
  shouldScanAsPublicTarget(_ownerRepo) { return true; },
  listPrivateRepoNames() { return []; },
  prStateForBranch(_repoDir) { return "UNKNOWN"; },
  prForBranch(_repoDir) { return { state: "UNKNOWN", number: "" }; },
  mergeStateForBranch(_repoDir) { return require("./merge-state").unknownMergeState("no forge handler for the origin host"); },
  hasOpenPrForBranch(_repoDir) { return true; },
  repoVisibility(_remoteUrl) { return null; },
};

const trackerStub = {
  isForgeScanTarget(_command) { return false; },
  vocabularyFor(_argv) { return { longValue: new Set(), longBool: new Set(), shortValue: new Set(), shortBool: new Set() }; },
  issueTitle(_remoteUrl, _ref, _opts) { return null; },
};

module.exports = { codehostStub, trackerStub };
