"use strict";

// glab ships as a native executable, so it is spawned without a shell: each argv
// element reaches glab intact and nothing passes through cmd.exe (DEP0190).

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
const { isPrPresentOrUnknown, stateForLocalHead } = require("./pr-state");
const GLAB_MR_STATES = Object.freeze({ opened: "OPEN", merged: "MERGED", closed: "CLOSED", locked: "CLOSED" });
// Defense-in-depth: only a plain hostname may become glab's --hostname argument.
const GLAB_HOSTNAME_SHAPE = /^[a-z0-9.-]+$/;

// glabHostArg(target) -> glab's --hostname value for a resolved remote target (the web host,
// plus an HTTP(S) non-default port), or null when the host is not a plain hostname.
function glabHostArg(t) {
  if (!t || typeof t.host !== "string" || !GLAB_HOSTNAME_SHAPE.test(t.host)) return null;
  const webPort = (t.scheme === "https" && t.port !== 443) || (t.scheme === "http" && t.port !== 80);
  return typeof t.port === "number" && webPort ? `${t.host}:${t.port}` : t.host;
}

// glabSettings(settings?) ->{gitlabHost, gitlabSshHost}, trimmed and lowercased; without an
// argument the forge-router readers decide (unchanged for every other caller).
function glabSettings(settings) {
  const clean = (v) => (typeof v === "string" ? v.trim().toLowerCase() : "");
  if (settings && typeof settings === "object") {
    return { gitlabHost: clean(settings.gitlabHost), gitlabSshHost: clean(settings.gitlabSshHost) };
  }
  const fr = require("../forge-router");
  return { gitlabHost: clean(fr.readGitlabHostConfig()), gitlabSshHost: clean(fr.readGitlabSshHostConfig()) };
}

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
        { encoding: "utf8", timeout: 10000 });
      if (r.error || r.status !== 0) return true; // fail-safe
      return (r.stdout || "").trim() === "private";
    } catch (e) {
      return true; // fail-safe
    }
  },
  // repoVisibility(remoteUrl, settings?) — settings {gitlabHost, gitlabSshHost} replaces the
  // forge-router reader when given. An SSH-alias URL is asked on the web host; an HTTP(S)
  // non-default port rides on --hostname. glab api has no --jq, so the JSON is parsed here.
  repoVisibility(remoteUrl, settings) {
    const { spawnSync } = require("child_process");
    try {
      const { resolveRemoteTarget } = require("../plan-sync/remote-url");
      const t = resolveRemoteTarget(remoteUrl, glabSettings(settings));
      if (t.type !== "gitlab" || !t.project) return null;
      const hostArg = glabHostArg(t);
      if (!hostArg) return null;
      // Without --hostname glab queries its default host, wrong for a self-hosted plan remote.
      const r = spawnSync("glab", ["api", "--hostname", hostArg, "projects/" + encodePath(t.project)],
        { encoding: "utf8", timeout: 15000, windowsHide: true });
      if (r.error || r.status !== 0) return null;
      const body = JSON.parse(r.stdout || "");
      if (!body || typeof body !== "object" || Array.isArray(body) || typeof body.visibility !== "string") return null;
      const v = body.visibility.trim().toLowerCase();
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
        { encoding: "utf8", timeout: 10000 });
      if (r.error || r.status !== 0) return true; // fail-safe: scan
      return (r.stdout || "").trim() !== "private"; // only private is non-public
    } catch (e) {
      return true;
    }
  },
  // One visibility-tagged membership listing; filtering and fail-to-[] live in ./private-repo-list.
  listPrivateRepoNames() {
    const { listVisibilityTagged } = require("./private-repo-list");
    return listVisibilityTagged("glab", ["api", "projects?membership=true&per_page=100", "--paginate",
      "--jq", ".[]|[.visibility,.path_with_namespace]|@tsv"]);
  },
  // MR state mapped onto the shared PR vocabulary (./pr-state.js).
  // opts.timeoutMs (default 8000) bounds the glab call.
  prStateForBranch(repoDir, opts) {
    const { spawnSync } = require("child_process");
    try {
      const r = spawnSync("glab", ["mr", "view", "--json", "state", "--jq", ".state"],
        { cwd: repoDir, encoding: "utf8", timeout: timeoutOf(opts) });
      if (r.error) return "UNKNOWN"; // glab not found
      if (r.status === 0) {
        const state = (r.stdout || "").trim().toLowerCase();
        if (state === "") return "UNKNOWN"; // exit 0 with no state is unexplained: fail closed
        return GLAB_MR_STATES[state] || "UNKNOWN";
      }
      // glab exits 1 both for "no MR" and for an API failure, so only the no-MR
      // message reads as NONE; any other failure is UNKNOWN (fail-closed).
      return isNoMrStderr(r.stderr) ? "NONE" : "UNKNOWN";
    } catch (e) {
      return "UNKNOWN";
    }
  },
  hasOpenPrForBranch(repoDir) {
    return isPrPresentOrUnknown(codehostGitlab.prStateForBranch(repoDir));
  },
  // { state, number } of the current branch's MR (bin/workflow/pr-state); number is the MR iid.
  // A MERGED MR is checked against the local HEAD (./pr-state.js) at the cost of one more read.
  prForBranch(repoDir, opts) {
    const state = codehostGitlab.prStateForBranch(repoDir, opts);
    if (state === "NONE" || state === "UNKNOWN") return { state, number: "" };
    const { spawnSync } = require("child_process");
    if (state === "MERGED") {
      let sha = "";
      try {
        const r = spawnSync("glab", ["mr", "view", "--json", "sha", "--jq", ".sha"],
          { cwd: repoDir, encoding: "utf8", timeout: timeoutOf(opts) });
        const out = r.status === 0 ? String(r.stdout || "").trim() : "";
        // --jq prints "null" for an absent field: only a commit id counts as reported.
        sha = /^[0-9a-f]{40,64}$/i.test(out) ? out : "";
      } catch (e) {
        sha = "";
      }
      const forHead = stateForLocalHead(repoDir, state, sha);
      if (forHead !== state) return { state: forHead, number: "" };
    }
    try {
      const r = spawnSync("glab", ["mr", "view", "--json", "iid", "--jq", ".iid"],
        { cwd: repoDir, encoding: "utf8", timeout: timeoutOf(opts) });
      const n = r.status === 0 ? String(r.stdout || "").trim() : "";
      return { state, number: /^\d+$/.test(n) ? n : "" };
    } catch (e) {
      return { state, number: "" };
    }
  },
  // { state, number, mergeState, url, error } from one glab MR JSON read; the
  // detailed_merge_status mapping lives in ./merge-state.js (SSOT).
  mergeStateForBranch(repoDir, opts) {
    const ms = require("./merge-state");
    const { spawnSync } = require("child_process");
    const timeoutMs = (opts && opts.timeoutMs) || ms.FORGE_QUERY_TIMEOUT_MS;
    let r;
    try {
      r = spawnSync("glab", ["mr", "view", "--output", "json"],
        { cwd: repoDir, encoding: "utf8", timeout: timeoutMs, windowsHide: true });
    } catch (e) {
      return ms.unknownMergeState("glab failed to start: " + (e && e.message));
    }
    const failure = ms.spawnFailure(r, "glab", timeoutMs);
    if (failure) return ms.unknownMergeState(failure);
    if (r.status !== 0) {
      if (isNoMrStderr(r.stderr)) return { state: "NONE", number: "", mergeState: "", url: "", error: "" };
      return ms.unknownMergeState(String(r.stderr || "").trim() || `glab exited ${r.status}`);
    }
    try {
      const mr = JSON.parse(String(r.stdout || "").trim());
      const state = GLAB_MR_STATES[String((mr && mr.state) || "").toLowerCase()];
      if (!state) return ms.unknownMergeState("glab answered an unreadable MR state");
      const iid = mr.iid !== undefined && mr.iid !== null ? String(mr.iid) : "";
      // mr.sha is the MR's head commit.
      return ms.mergeStateForLocalHead(repoDir, {
        state,
        number: /^\d+$/.test(iid) ? iid : "",
        mergeState: ms.gitlabMergeState(mr),
        url: typeof mr.web_url === "string" ? mr.web_url : "",
        error: "",
      }, mr.sha);
    } catch (e) {
      return ms.unknownMergeState("glab answered malformed JSON");
    }
  },
};

// glab exits 1 both for "no MR" and for an API failure, so only the no-MR message reads as NONE.
function isNoMrStderr(stderr) {
  return /no open merge request|merge request not found|no merge requests? found/i.test(String(stderr || ""));
}

function timeoutOf(opts) {
  const t = opts && Number(opts.timeoutMs);
  return Number.isFinite(t) && t > 0 ? t : 8000;
}

module.exports = { trackerGitlab, codehostGitlab, encodePath, glabHostArg, GLAB_SCAN_TARGET_REGEX, GLAB_API_WRITE_REGEX };
