"use strict";

// On Windows, spawnSync without shell:true cannot resolve .cmd wrappers via PATHEXT.
const WIN32 = process.platform === "win32";

// GitLab forge tracker (#2307). glab issue/mr writes are scan targets; the body
// flag is --description (gh's is --body), which extractTexts already covers.
const GLAB_SCAN_TARGET_REGEX =
  /\bglab\b\s+(?:mr\s+(?:create|update|close|note|comment)|issue\s+(?:create|update|close|note|comment))\b/;
const GLAB_API_WRITE_REGEX =
  /\bglab\b\s+api\b.*?(?:-X\s+(?:POST|PATCH|PUT|DELETE)|--method(?:\s+|=)(?:POST|PATCH|PUT|DELETE))/i;

const trackerGitlab = {
  isForgeScanTarget(command) {
    if (typeof command !== "string" || command.length === 0) return false;
    return GLAB_SCAN_TARGET_REGEX.test(command) || GLAB_API_WRITE_REGEX.test(command);
  },
  vocabularyFor(argv) {
    return require("../glab-flag-vocab").vocabularyFor(argv);
  },
};

// glab api project endpoints take the URL-encoded project path (/ → %2F), so a
// nested namespace (group/subgroup/project) survives interpolation intact.
function encodePath(p) {
  return String(p).split("/").map(encodeURIComponent).join("%2F");
}

const VISIBILITY_VALUES = new Set(["public", "private", "internal"]);

// GitLab codehost descriptor (#2308). Same four methods, same signatures as
// codehostGithub (CPR-ORTH). isPrivateRepo fail-safe returns true (private),
// intentionally stricter than codehostStub's false, so repo names are never
// leaked when glab is unavailable. forge-router / parse-remote-url are
// lazy-required inside each method so the forge-router ↔ forge/gitlab cycle
// resolves at call time, not load time.
const codehostGitlab = {
  isPrivateRepo(remoteUrl) {
    const { resolveForgeTarget } = require("../parse-remote-url");
    const { readGitlabHostConfig } = require("../forge-router");
    const { spawnSync } = require("child_process");
    const { type, project } = resolveForgeTarget(remoteUrl, { gitlabHost: readGitlabHostConfig() });
    // fail-safe: when glab is unavailable or the path is unresolvable, treat the
    // repo as private so its name is never leaked to glab (#2308 CPR-ORTH contract).
    if (type !== "gitlab" || !project) return true;
    try {
      const r = spawnSync("glab", ["api", "projects/" + encodePath(project), "--jq", ".visibility"],
        { encoding: "utf8", timeout: 10000, shell: WIN32 });
      if (r.error || r.status !== 0) return true; // fail-safe
      return (r.stdout || "").trim() === "private";
    } catch (e) {
      return true; // fail-safe
    }
  },
  repoVisibility(remoteUrl) {
    const { spawnSync } = require("child_process");
    try {
      const { resolveForgeTarget } = require("../parse-remote-url");
      const { readGitlabHostConfig } = require("../forge-router");
      const { type, project } = resolveForgeTarget(remoteUrl, { gitlabHost: readGitlabHostConfig() });
      if (type !== "gitlab" || !project) return null;
      const r = spawnSync("glab", ["api", "projects/" + encodePath(project), "--jq", ".visibility"],
        { encoding: "utf8", timeout: 15000, shell: WIN32, windowsHide: true });
      if (r.error || r.status !== 0) return null;
      const v = (r.stdout || "").trim().toLowerCase();
      return VISIBILITY_VALUES.has(v) ? v : null;
    } catch (e) {
      return null;
    }
  },
  shouldScanAsPublicTarget(projectId) {
    const { spawnSync } = require("child_process");
    try {
      if (!projectId || typeof projectId !== "string") return true;
      const r = spawnSync("glab", ["api", "projects/" + encodePath(projectId), "--jq", ".visibility"],
        { encoding: "utf8", timeout: 10000, shell: WIN32 });
      if (r.error || r.status !== 0) return true; // fail-safe: scan
      return (r.stdout || "").trim() !== "private"; // only private is non-public
    } catch (e) {
      return true;
    }
  },
  // Union of private and internal projects; each query fails independently to [].
  listPrivateRepoNames() {
    const { spawnSync } = require("child_process");
    const list = (visibility) => {
      // cmd.exe (shell on Windows) splits an unquoted `&`, so the query is quoted there.
      const query = "projects?membership=true&visibility=" + visibility + "&per_page=100";
      try {
        const r = spawnSync("glab",
          ["api", WIN32 ? '"' + query + '"' : query, "--paginate", "--jq", ".[].path_with_namespace"],
          { encoding: "utf8", timeout: 10000, shell: WIN32 });
        if (r.error || r.status !== 0) return [];
        return (r.stdout || "").split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
      } catch (e) {
        return [];
      }
    };
    return [...new Set([...list("private"), ...list("internal")])];
  },
  hasOpenPrForBranch(repoDir) {
    const { spawnSync } = require("child_process");
    try {
      const r = spawnSync("glab", ["mr", "view", "--json", "state", "--jq", ".state"],
        { cwd: repoDir, encoding: "utf8", timeout: 8000, shell: WIN32 });
      if (r.error) return true; // fail-safe: glab not found
      if (r.status === 0) {
        const state = (r.stdout || "").trim();
        return state === "opened" || state === "merged";
      }
      return false; // status 1 = no MR for current branch
    } catch (e) {
      return true;
    }
  },
};

module.exports = { trackerGitlab, codehostGitlab, encodePath, GLAB_SCAN_TARGET_REGEX, GLAB_API_WRITE_REGEX };
