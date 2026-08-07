"use strict";

const { findRepoRoot, normalizeForCompare } = require("../git-repo-detection");
const { isAllowedScratchpadTarget } = require("../../lib/claude-scratchpad-base");
const { expandStaticShellTokens } = require("../../lib/bash-write-targets/helpers");
const { isContainedUnder, normalizeTarget } = require("./target-normalize");

function isInSessionScope(repoRoot, sessionRoots) {
  if (!repoRoot) return false;
  const norm = normalizeForCompare(repoRoot);
  return norm ? sessionRoots.has(norm) : false;
}

// True if all targets resolve to repos outside the session scope.
// findRepoRoot()==null (non-git path) is also treated as outside scope (allow).
function areAllBashTargetsOutsideSessionScope(targets, sessionRoots) {
  if (!targets || targets.length === 0) return false;
  for (const rawT of targets) {
    const t = normalizeTarget(rawT);
    // Malformed target → fail-closed: treat as in-session (not outside scope) so
    // the command is not silently allowed. Return false = "not all outside".
    if (t.malformed === true) return false;
    // Strip surrounding shell quotes from the path (some extractors return raw
    // token strings that include the original quotes) — the quote-strip that used
    // to live in universal-target-allow's caller is centralized here (CPR-SSOT).
    const rawPath = String(t.path).replace(/^["']|["']$/g, "");
    let repo;
    if (t.resolveVia === "self") {
      // path IS the resolved scope root — do NOT call findRepoRoot.
      repo = rawPath;
    } else {
      // "ancestor" (default): path is a file inside a repo; resolve upward.
      repo = findRepoRoot(rawPath);
    }
    if (repo !== null && isInSessionScope(repo, sessionRoots)) return false;
  }
  return true;
}

// True if all targets are provably under getWorkflowPlansDir().
// Used to allow out-of-session-scope Bash writes from a non-git CWD (#878):
// non-git CWD is allowed ONLY when every target is under plans-dir, preserving
// fail-closed denial for arbitrary /tmp or external paths.
function areAllBashTargetsUnderPlansDir(targets) {
  if (!targets || targets.length === 0) return false;
  try {
    const nodePath = require("path");
    const { getWorkflowPlansDir } = require("../../lib/workflow-plans-dir");
    let plansDir;
    try { plansDir = getWorkflowPlansDir(); } catch (_) { return false; }
    if (!plansDir) return false;
    // #1780 H-3: case folding is decided per-filesystem by isContainedUnder(),
    // not by process.platform. See target-normalize.js.
    const normPlans = nodePath.resolve(plansDir);
    const isUnder = (rawT) => {
      const t = normalizeTarget(rawT);
      if (t.malformed === true) return false; // fail-closed: not provably under plans-dir
      const raw = String(t.path).replace(/^["']|["']$/g, ""); // strip surrounding quotes
      let resolved = raw;
      if (raw.includes("$") || raw.includes("~")) {
        const expanded = expandStaticShellTokens(raw, { fromQuotedContext: "unquoted" });
        if (expanded === null) return false; // fail-closed: unresolvable $VAR
        resolved = expanded;
      }
      const n = nodePath.resolve(resolved);
      return isContainedUnder(n, normPlans);
    };
    return targets.every(isUnder);
  } catch (_) {
    return false; // fail-closed
  }
}

// True if all targets are provably under the session scratchpad allow root (H2:
// the SCRATCHPAD dir when the harness exposes it, else <os-tmpdir>/claude/) AND
// outside every git repo root. NOT a generic temp-dir allow: /tmp/evil.md,
// /var/tmp/evil.md, <tmpdir>/evil.md (root), and /tmp/not-claude/... all remain blocked.
// F1 hardening: the outside-repo clause defends against a poisoned TEMP/TMP that nests
// the claude base inside a repo (SSOT base + guard live in lib/claude-scratchpad-base.js).
function areAllBashTargetsUnderClaude(targets) {
  if (!targets || targets.length === 0) return false;
  try {
    const nodePath = require("path");
    const isUnder = (rawT) => {
      const t = normalizeTarget(rawT);
      if (t.malformed === true) return false;
      const raw = String(t.path).replace(/^["']|["']$/g, "");
      let resolved = raw;
      if (raw.includes("$") || raw.includes("~")) {
        const expanded = expandStaticShellTokens(raw, { fromQuotedContext: "unquoted" });
        if (expanded === null) return false;
        resolved = expanded;
      }
      // Reject path traversal
      if (/(?:^|[/\\])\.\.(?:[/\\]|$)/.test(resolved)) return false;
      const n = nodePath.resolve(resolved);
      // Must be strictly under the scratchpad allow root AND outside every repo root.
      return isAllowedScratchpadTarget(n, findRepoRoot);
    };
    return targets.every(isUnder);
  } catch (_) {
    return false; // fail-closed
  }
}

module.exports = {
  isInSessionScope,
  areAllBashTargetsOutsideSessionScope,
  areAllBashTargetsUnderPlansDir,
  areAllBashTargetsUnderClaude,
};
