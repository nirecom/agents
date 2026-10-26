"use strict";
// WF target repo set for the commit gate (#1633): the session-start repo plus the
// worktrees the intent's `## worktrees` section declares. The 1:1 vs 1:N policy
// is #2627. Callers outside this module use classifyDirAgainstWfTargetRepos and
// readMainRepoLocation only.
// "possibly-in": a declared member has not resolved yet (its worktree is not
// created), so membership of any other repo is unknowable — the gate treats it as
// "in". Distinct from "location-unknown", where the commit dir itself is not a repo.

const fs = require("fs");
const { toWindowsPath } = require("./branch-diff");
const { resolveRepoLocation } = require("./repo-identity");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");

// Entries of the intent's `## worktrees` section; [] when absent or unreadable.
function parseWorktrees(intentPath) {
  let text;
  try {
    text = fs.readFileSync(intentPath, "utf8");
  } catch (_) {
    return [];
  }
  const results = [];
  let inWorktrees = false;
  let current = null;
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trimEnd();
    if (/^##\s+worktrees\s*$/i.test(line)) { inWorktrees = true; continue; }
    if (inWorktrees && /^##/.test(line)) break;
    if (!inWorktrees) continue;
    const repoMatch = /^-\s+repo:\s+(.+)$/.exec(line);
    if (repoMatch) { current = { repo: repoMatch[1].trim(), worktree_path: null }; continue; }
    const pathMatch = /^\s+worktree_path:\s+(.+)$/.exec(line);
    if (pathMatch && current) {
      current.worktree_path = pathMatch[1].trim();
      results.push(current);
      current = null;
    }
  }
  return results;
}

// The intent a session reads is <first_session_id>-intent.md (#2633, #2748); null when absent.
function resolveIntentPath(sessionId, state) {
  try {
    const { resolvePlanArtifactOwner } = require("../workflow-state/plan-artifact-owner");
    const owner = resolvePlanArtifactOwner(sessionId, "intent", state || null, { plansDir: getWorkflowPlansDir() });
    return owner.exists ? owner.path : null;
  } catch (_) {
    return null;
  }
}

function readWfTargetRepos(sessionId, state) {
  const cwd = state && state.session_start_context && state.session_start_context.cwd;
  if (typeof cwd !== "string" || cwd.trim().length === 0) {
    return { ok: false, reason: "session-start-cwd-missing" };
  }
  const mainLocation = resolveRepoLocation(toWindowsPath(cwd));
  if (!mainLocation) {
    return { ok: false, reason: "session-start-cwd-not-a-repo" };
  }
  const members = [
    { origin: "session-start", declaredPath: cwd, repoSlug: null, location: mainLocation },
  ];

  const intentPath = resolveIntentPath(sessionId, state);
  if (intentPath) {
    for (const entry of parseWorktrees(intentPath)) {
      if (!entry.worktree_path) continue;
      members.push({
        origin: "intent-worktrees",
        declaredPath: entry.worktree_path,
        repoSlug: entry.repo || null,
        location: resolveRepoLocation(toWindowsPath(entry.worktree_path)),
      });
    }
  }

  return { ok: true, members };
}

function findMainMember(members) {
  return Array.isArray(members) ? members.find((m) => m && m.origin === "session-start") || null : null;
}

function readMainRepoLocation(members) {
  const main = findMainMember(members);
  return main ? main.location : null;
}

function classifyDirAgainstWfTargetRepos(members, dir) {
  if (!Array.isArray(members) || typeof dir !== "string" || dir.length === 0) {
    return { verdict: "location-unknown", location: null };
  }
  const location = resolveRepoLocation(toWindowsPath(dir));
  if (!location) return { verdict: "location-unknown", location: null };

  if (members.some((m) => m && m.location && m.location.commonDir === location.commonDir)) {
    return { verdict: "in", location };
  }
  if (members.some((m) => m && m.location === null)) return { verdict: "possibly-in", location };
  return { verdict: "out", location };
}

module.exports = {
  readWfTargetRepos,
  readMainRepoLocation,
  findMainMember,
  classifyDirAgainstWfTargetRepos,
  parseWorktrees,
};
