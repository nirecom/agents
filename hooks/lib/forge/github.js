"use strict";

// gh ships as a native executable, so it is spawned without a shell: each argv
// element reaches gh intact and nothing passes through cmd.exe (DEP0190).

// GitHub forge descriptors (#2307). The gh scan regexes live here (CPR-SSOT):
// forge-write-extract.js re-imports GH_API_WRITE_REGEX / GH_REPO_WRITE_REGEX from
// this module instead of redeclaring them.
const GH_ISSUE_PR_WRITE_RE =
  /\bgh\b\s+(?:pr\s+(?:create|new|edit|close|comment|review)|issue\s+(?:create|new|edit|close|comment))\b/;
const GH_API_WRITE_REGEX =
  /\bgh\b\s+api\b.*?(?:-X\s+(?:POST|PATCH|PUT|DELETE)|--method(?:\s+|=)(?:POST|PATCH|PUT|DELETE))/i;
const GH_REPO_WRITE_REGEX = /\bgh\b\s+repo\s+(?:create|edit)\b/;
const VISIBILITY_VALUES = new Set(["public", "private", "internal"]);
const PR_STATES = new Set(["OPEN", "MERGED", "CLOSED"]);
const { isPrPresentOrUnknown, stateForLocalHead } = require("./pr-state");

// gh exits 1 both for "no pull requests found" and for network/auth failures, so
// only the no-PR message reads as NONE; any other failure is UNKNOWN (fail-closed).
function isNoPrResult(r) {
  return Boolean(r) && r.status === 1 && /no pull requests? found/i.test(String(r.stderr || ""));
}

const codehostGithub = {
  isPrivateRepo(remoteUrl) {
    const { parseOriginOwnerRepo } = require("../parse-remote-url");
    const { spawnSync } = require("../limited-child-process");
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
  repoVisibility(remoteUrl) {
    const { parseOriginOwnerRepo } = require("../parse-remote-url");
    const { spawnSync } = require("../limited-child-process");
    try {
      const parsed = parseOriginOwnerRepo(remoteUrl);
      if (!parsed.ok) return null;
      const r = spawnSync("gh", ["api", "repos/" + parsed.ownerRepo, "--jq", ".visibility"], {
        encoding: "utf8",
        timeout: 15000,
        windowsHide: true,
      });
      if (r.error || r.status !== 0) return null;
      const v = (r.stdout || "").trim().toLowerCase();
      return VISIBILITY_VALUES.has(v) ? v : null;
    } catch (e) {
      return null;
    }
  },
  shouldScanAsPublicTarget(ownerRepo) {
    const { spawnSync } = require("../limited-child-process");
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
  // One visibility-tagged listing; filtering and fail-to-[] live in ./private-repo-list.
  listPrivateRepoNames() {
    const { listVisibilityTagged } = require("./private-repo-list");
    return listVisibilityTagged("gh", ["repo", "list", "--limit", "1000", "--json", "nameWithOwner,visibility",
      "--jq", ".[]|[.visibility,.nameWithOwner]|@tsv"]);
  },
  // PR state of the current branch: OPEN | MERGED | CLOSED | NONE (no PR) |
  // UNKNOWN (gh unavailable or failed). Callers choose their own fail direction.
  // opts.timeoutMs (default 8000) bounds the gh call.
  prStateForBranch(repoDir, opts) {
    // Lazy require breaks the cycle: gh-detect requires forge-router at top level,
    // forge-router requires this module at top level.
    const { findGhInPath, toMsys2Path } = require("../../workflow-gate/gh-detect");
    const { spawnSync } = require("../limited-child-process");
    const ghPath = findGhInPath();
    const ghArg = ghPath ? toMsys2Path(ghPath) : "gh";
    let r;
    try {
      r = spawnSync("bash", ["-c", '"$1" pr view --json state -q .state', "--", ghArg], {
        cwd: repoDir,
        encoding: "utf8",
        timeout: timeoutOf(opts),
      });
    } catch (e) {
      return "UNKNOWN";
    }
    if (r && r.status === 0) {
      const state = (r.stdout || "").trim().toUpperCase();
      return PR_STATES.has(state) ? state : "UNKNOWN";
    }
    if (isNoPrResult(r)) return "NONE";
    return "UNKNOWN";
  },
  hasOpenPrForBranch(repoDir) {
    return isPrPresentOrUnknown(codehostGithub.prStateForBranch(repoDir));
  },
  // { state, number } of the current branch's PR (bin/workflow/pr-state); number "" when none,
  // and when the PR was merged from another commit than the local HEAD (./pr-state.js).
  prForBranch(repoDir, opts) {
    const { findGhInPath, toMsys2Path } = require("../../workflow-gate/gh-detect");
    const { spawnSync } = require("../limited-child-process");
    const ghPath = findGhInPath();
    let r;
    try {
      r = spawnSync("bash", ["-c", '"$1" pr view --json state,number,headRefOid', "--", ghPath ? toMsys2Path(ghPath) : "gh"], {
        cwd: repoDir, encoding: "utf8", timeout: timeoutOf(opts),
      });
    } catch (e) {
      return { state: "UNKNOWN", number: "" };
    }
    if (isNoPrResult(r)) return { state: "NONE", number: "" };
    if (!r || r.status !== 0) return { state: "UNKNOWN", number: "" };
    try {
      const pr = JSON.parse(String(r.stdout || "").trim());
      const raw = String(pr.state || "").toUpperCase();
      const reported = PR_STATES.has(raw) ? raw : "UNKNOWN";
      const state = stateForLocalHead(repoDir, reported, pr.headRefOid);
      return { state, number: state === reported && Number.isInteger(pr.number) ? String(pr.number) : "" };
    } catch (e) {
      return { state: "UNKNOWN", number: "" };
    }
  },
  // { state, number, mergeState, url, error } in one gh call (./merge-state.js). gh is
  // spawned directly (no bash wrapper) so the timeout kills the gh process itself.
  mergeStateForBranch(repoDir, opts) {
    const ms = require("./merge-state");
    const { spawnSync } = require("../limited-child-process");
    const timeoutMs = (opts && opts.timeoutMs) || ms.FORGE_QUERY_TIMEOUT_MS;
    let r;
    try {
      r = spawnSync("gh", ["pr", "view", "--json", "state,number,mergeStateStatus,url,headRefOid"],
        { cwd: repoDir, encoding: "utf8", timeout: timeoutMs, windowsHide: true });
    } catch (e) {
      return ms.unknownMergeState("gh failed to start: " + (e && e.message));
    }
    const failure = ms.spawnFailure(r, "gh", timeoutMs);
    if (failure) return ms.unknownMergeState(failure);
    if (isNoPrResult(r)) return { state: "NONE", number: "", mergeState: "", url: "", error: "" };
    if (r.status !== 0) return ms.unknownMergeState(String(r.stderr || "").trim() || `gh exited ${r.status}`);
    try {
      const pr = JSON.parse(String(r.stdout || "").trim());
      const state = String(pr.state || "").toUpperCase();
      if (!PR_STATES.has(state)) return ms.unknownMergeState("gh answered an unreadable PR state");
      return ms.mergeStateForLocalHead(repoDir, {
        state,
        number: Number.isInteger(pr.number) ? String(pr.number) : "",
        mergeState: String(pr.mergeStateStatus || "").toUpperCase(),
        url: typeof pr.url === "string" ? pr.url : "",
        error: "",
      }, pr.headRefOid);
    } catch (e) {
      return ms.unknownMergeState("gh answered malformed JSON");
    }
  },
};

function timeoutOf(opts) {
  const t = opts && Number(opts.timeoutMs);
  return Number.isFinite(t) && t > 0 ? t : 8000;
}

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
