"use strict";
// PR / MR URL for the AUTO_MERGE_PR=off refusal text (#2527 4-3). Looked up only when the
// refusal fires, bounded to 3 seconds; any failure falls back to the forge's
// "view --web" command so the refusal text never depends on the network.

const { spawnSync } = require("child_process");

const LOOKUP_TIMEOUT_MS = 3000;

function fallbackOf(kind) {
  return kind === "glab-mr-merge" ? "glab mr view --web" : "gh pr view --web";
}

function lookupUrl(kind, repoDir) {
  const opts = { cwd: repoDir || undefined, encoding: "utf8", timeout: LOOKUP_TIMEOUT_MS, windowsHide: true };
  if (kind === "glab-mr-merge") {
    const r = spawnSync("glab", ["mr", "view", "--output", "json"], opts);
    if (r.error || r.status !== 0) return null;
    const url = JSON.parse(r.stdout || "{}").web_url;
    return typeof url === "string" ? url : null;
  }
  const r = spawnSync("gh", ["pr", "view", "--json", "url", "-q", ".url"], opts);
  if (r.error || r.status !== 0) return null;
  return (r.stdout || "").trim() || null;
}

// releasePrUrl(kind, repoDir) -> "<url>" or the "view --web" command.
function releasePrUrl(kind, repoDir) {
  try {
    const url = lookupUrl(kind, repoDir);
    if (url && /^https?:\/\/\S+$/.test(url)) return url;
  } catch (_) { /* fall back */ }
  return fallbackOf(kind);
}

module.exports = { releasePrUrl, LOOKUP_TIMEOUT_MS };
