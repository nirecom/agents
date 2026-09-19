"use strict";
// Forge routing (#2307). Two independent axes — codehost (repo hosting: gh/glab)
// and tracker (issue/MR system: github/gitlab/jira) — each resolve to a
// descriptor. There is NO silent GitHub fallback: an unresolvable axis lands on a
// no-op stub, never on the github handler (the security invariant).
const { detectForgeType } = require("./parse-remote-url");
const { codehostGithub, trackerGithub } = require("./forge/github");
const { trackerGitlab } = require("./forge/gitlab");
const { codehostStub, trackerStub } = require("./forge/stub");

const FORGE_DESCRIPTORS = {
  github: { type: "github", codehost: codehostGithub, tracker: trackerGithub },
  gitlab: { type: "gitlab", codehost: codehostStub, tracker: trackerGitlab },
  jira: { type: "jira", codehost: null, tracker: trackerStub },
};

// Codehost descriptor for a git remote URL, as a FLAT object: callers reach
// .isPrivateRepo / .hasOpenPrForBranch directly. An unknown host routes to the
// no-op stub — never the gitlab entry, to avoid misrepresenting the codehost type.
function resolveCodehostDescriptor(remoteUrl) {
  const { type } = detectForgeType(remoteUrl);
  const desc = FORGE_DESCRIPTORS[type];
  const codehost = (desc && desc.codehost) || codehostStub;
  const resolvedType = desc ? desc.type : "unknown";
  return Object.assign({ type: resolvedType }, codehost);
}

// Tracker descriptor. FORGE_TRACKER (from an env key-value object) selects the
// tracker explicitly; unset/empty follows the codehost type; an explicit but
// unregistered value resolves to the unknown/stub tracker — never the codehost.
function resolveTrackerDescriptor(envObj, codehostType) {
  const raw = (envObj && typeof envObj.FORGE_TRACKER === "string") ? envObj.FORGE_TRACKER.trim().toLowerCase() : null;
  let type;
  if (!raw) {
    type = codehostType || "unknown";
  } else if (Object.prototype.hasOwnProperty.call(FORGE_DESCRIPTORS, raw)) {
    type = raw;
  } else {
    type = "unknown";
  }
  const desc = FORGE_DESCRIPTORS[type];
  const tracker = desc ? desc.tracker : trackerStub;
  return Object.assign({ type }, tracker);
}

// The configured FORGE_TRACKER value (trimmed, lowercased) or null when unset.
function readTrackerConfig(projectRoot) {
  const env = require("./load-env").readEffectiveEnvFile(projectRoot);
  const val = (env && typeof env.FORGE_TRACKER === "string") ? env.FORGE_TRACKER.trim().toLowerCase() : null;
  return val || null;
}

module.exports = { resolveCodehostDescriptor, resolveTrackerDescriptor, readTrackerConfig, detectForgeType, FORGE_DESCRIPTORS };
