"use strict";

// No-op forge descriptors (#2307). A codehost/tracker that has no real handler
// resolves here instead of silently reusing GitHub's — the security invariant is
// "no fallback". Each method's return value is the fail-safe for its axis.
const codehostStub = {
  isPrivateRepo(_remoteUrl) { return false; },
  shouldScanAsPublicTarget(_ownerRepo) { return true; },
  listPrivateRepoNames() { return []; },
  hasOpenPrForBranch(_repoDir) { return true; },
};

const trackerStub = {
  isForgeScanTarget(_command) { return false; },
  vocabularyFor(_argv) { return { longValue: new Set(), longBool: new Set(), shortValue: new Set(), shortBool: new Set() }; },
};

module.exports = { codehostStub, trackerStub };
