"use strict";

// GitHub forge descriptors (#2307). The gh scan regexes live here (CPR-SSOT):
// forge-write-extract.js re-imports GH_API_WRITE_REGEX / GH_REPO_WRITE_REGEX from
// this module instead of redeclaring them.
const GH_ISSUE_PR_WRITE_RE =
  /\bgh\b\s+(?:pr\s+(?:create|new|edit|close|comment|review)|issue\s+(?:create|new|edit|close|comment))\b/;
const GH_API_WRITE_REGEX =
  /\bgh\b\s+api\b.*?(?:-X\s+(?:POST|PATCH|PUT|DELETE)|--method(?:\s+|=)(?:POST|PATCH|PUT|DELETE))/i;
const GH_REPO_WRITE_REGEX = /\bgh\b\s+repo\s+(?:create|edit)\b/;

const codehostGithub = {
  isPrivateRepo(remoteUrl) {
    const { parseOriginOwnerRepo } = require("../parse-remote-url");
    const { spawnSync } = require("child_process");
    const parsed = parseOriginOwnerRepo(remoteUrl);
    if (!parsed.ok) return false;
    try {
      const result = spawnSync("gh", ["api", "repos/" + parsed.ownerRepo, "--jq", ".private"], {
        encoding: "utf8",
        timeout: 10000,
      });
      if (result.error || result.status !== 0) return false;
      return (result.stdout || "").trim() === "true";
    } catch (e) {
      return false;
    }
  },
  shouldScanAsPublicTarget(ownerRepo) {
    const { spawnSync } = require("child_process");
    try {
      if (!ownerRepo || typeof ownerRepo !== "string") return true;
      const result = spawnSync("gh", ["api", "repos/" + ownerRepo, "--jq", ".private"], {
        encoding: "utf8",
        timeout: 10000,
      });
      if (result.error || result.status !== 0) return true;
      const out = (result.stdout || "").trim();
      if (out === "true") return false;
      if (out === "false") return true;
      return true;
    } catch (e) {
      return true;
    }
  },
  listPrivateRepoNames() {
    const { spawnSync } = require("child_process");
    try {
      const result = spawnSync(
        "gh",
        ["repo", "list", "--limit", "1000", "--visibility", "private", "--json", "nameWithOwner", "--jq", ".[].nameWithOwner"],
        { encoding: "utf8", timeout: 10000 }
      );
      if (result.error || result.status !== 0) return [];
      return (result.stdout || "").split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    } catch (e) {
      return [];
    }
  },
  hasOpenPrForBranch(repoDir) {
    // Lazy require breaks the cycle: gh-detect requires forge-router at top level,
    // forge-router requires this module at top level.
    const { findGhInPath, toMsys2Path } = require("../../workflow-gate/gh-detect");
    const { spawnSync } = require("child_process");
    const ghPath = findGhInPath();
    const ghArg = ghPath ? toMsys2Path(ghPath) : "gh";
    let r;
    try {
      r = spawnSync("bash", ["-c", '"$1" pr view --json state -q .state', "--", ghArg], {
        cwd: repoDir,
        encoding: "utf8",
        timeout: 8000,
      });
    } catch (e) {
      return true;
    }
    if (r && r.status === 0) {
      const state = (r.stdout || "").trim();
      return state === "OPEN" || state === "MERGED";
    }
    if (r && r.status === 1) return false;
    return true;
  },
};

const trackerGithub = {
  isForgeScanTarget(command) {
    if (typeof command !== "string" || command.length === 0) return false;
    return GH_ISSUE_PR_WRITE_RE.test(command) || GH_API_WRITE_REGEX.test(command) || GH_REPO_WRITE_REGEX.test(command);
  },
  vocabularyFor(argv) {
    return require("../gh-flag-vocab").vocabularyFor(argv);
  },
};

module.exports = { codehostGithub, trackerGithub, GH_API_WRITE_REGEX, GH_REPO_WRITE_REGEX };
