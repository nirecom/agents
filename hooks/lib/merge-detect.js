// hooks/lib/merge-detect.js
// Classifier for "merge to protected branch" commands.
// Used by workflow-gate.js (PreToolUse hard gate) and workflow-mark.js (post-push reset).
//
// Returns { hit, kind } where kind is one of:
//   "gh-pr-merge"          — gh pr merge (any flags including --auto)
//   "git-push-protected"   — git push that targets a protected branch
//
// Known gaps (documented):
// - Non-standard flag forms like "--repo=origin main" are not parsed (canonical forms only).
// - This hook only fires for Claude Code Bash tool invocations; terminal sessions bypass it.
//   This is by design — the gate is a workflow assistant, not OS-level access control.

"use strict";

const { parseGitGlobalOptions } = require("./parse-git-args");
const { splitShellCommands } = require("./shell-segments");

function getProtectedBranches() {
  const env = (process.env.DEFAULT_BRANCHES || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return env.length ? env : ["main", "master"];
}

function checkSegment(segment) {
  if (!segment) return { hit: false, kind: null };

  // gh pr merge — any flags (--auto, --squash, --rebase, --merge, --delete-branch, etc.)
  if (/^\s*gh\s+pr\s+merge\b/.test(segment)) {
    return { hit: true, kind: "gh-pr-merge" };
  }

  // Must start with "git" to be a git push
  if (!/^\s*git\b/.test(segment)) {
    return { hit: false, kind: null };
  }

  const { subcommand, rest } = parseGitGlobalOptions(segment);
  if (subcommand !== "push") return { hit: false, kind: null };

  const protectedBranches = getProtectedBranches();

  // --all / --mirror push every local branch including protected ones
  if (/(?:^|\s)--(?:all|mirror)\b/.test(" " + rest)) {
    return { hit: true, kind: "git-push-protected" };
  }

  // Tokenize quote-aware, drop flags, drop remote name (first non-flag)
  const tokens = (rest.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || []).filter(
    (t) => !t.startsWith("-")
  );
  const refspecs = tokens.slice(1);
  if (refspecs.length === 0) return { hit: false, kind: null };

  for (const spec of refspecs) {
    const s = spec.replace(/^\+/, "");  // strip force-shorthand
    let dst = s.includes(":") ? s.split(":")[1] : s;
    dst = (dst || "").replace(/^refs\/heads\//, "");
    if (dst && protectedBranches.includes(dst)) {
      return { hit: true, kind: "git-push-protected" };
    }
  }
  return { hit: false, kind: null };
}

function isMergeToProtectedCommand(command, _repoDir) {
  if (!command || typeof command !== "string") {
    return { hit: false, kind: null };
  }
  for (const segment of splitShellCommands(command)) {
    const result = checkSegment(segment);
    if (result.hit) return result;
  }
  return { hit: false, kind: null };
}

module.exports = { isMergeToProtectedCommand, getProtectedBranches };
