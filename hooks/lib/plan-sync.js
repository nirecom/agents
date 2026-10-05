"use strict";
// hooks/lib/plan-sync.js — dispatch only: re-exports the plan-sync sibling modules.
// Hooks, bin/plan-sync-init and tests require this file, never the siblings.
// Design: docs/architecture/claude-code/plan-sync.md.
const remoteUrl = require("./plan-sync/remote-url");
const allowlist = require("./plan-sync/allowlist");
const provision = require("./plan-sync/provision");
const commitPush = require("./plan-sync/commit-push");

module.exports = {
  isAllowedRemoteUrl: remoteUrl.isAllowedRemoteUrl,
  redactUrl: remoteUrl.redactUrl,
  redactText: remoteUrl.redactText,
  parseGitHubRemote: remoteUrl.parseGitHubRemote,
  blobUrlFor: remoteUrl.blobUrlFor,
  renderGitignore: allowlist.renderGitignore,
  isSyncTarget: allowlist.isSyncTarget,
  INIT_VERSION: provision.INIT_VERSION,
  resolveRemoteUrl: provision.resolveRemoteUrl,
  effectivePushUrl: provision.effectivePushUrl,
  checkProvisioned: provision.checkProvisioned,
  provisionRepo: provision.provisionRepo,
  syncPlanFile: commitPush.syncPlanFile,
  publishedBlobUrl: commitPush.publishedBlobUrl,
  readVerifiedRegularFile: commitPush.readVerifiedRegularFile,
};
