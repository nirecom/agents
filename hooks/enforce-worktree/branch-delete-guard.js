"use strict";

const { spawnSync } = require("child_process");
const { stripQuotedArgs } = require("../lib/strip-quoted-args");
const { hasShellChaining } = require("./shared-cmd-utils");

// True if cmd is `git [opts] [-C path] branch -d|-D <branch> [...]`.
// Strict subcommand position: only flag tokens (and their values) may appear
// between `git` and `branch`, mirroring isAllowedFastForwardMerge.
function isBranchDeleteCommand(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  if (!/\bgit\b/.test(cmd)) return false;
  const stripped = stripQuotedArgs(cmd);
  return /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*branch\b[^|;&]*\s-[dD](?:\s|$)/.test(stripped);
}

// Extract the target branch name from `git ... branch -d|-D <branch>`.
// Uses the ORIGINAL (un-stripped) cmd so quoted branch names like "fix/foo"
// are tokenised correctly by the quote-aware re.exec loop below.
// Returns null if unparseable.
function parseBranchDeleteTarget(cmd) {
  if (!isBranchDeleteCommand(cmd)) return null;
  // After the `branch -d|-D` flag, the next non-flag positional token is the branch.
  const m = cmd.match(/\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*branch\b([^|;&]*)/);
  if (!m) return null;
  const tokens = [];
  const re = /"([^"]+)"|'([^']+)'|(\S+)/g;
  let mm;
  while ((mm = re.exec(m[1])) !== null) tokens.push(mm[1] || mm[2] || mm[3]);
  // Find -d or -D, then the next non-flag token
  let sawDeleteFlag = false;
  for (const tok of tokens) {
    if (!sawDeleteFlag) {
      if (/^-[dD]$/.test(tok)) sawDeleteFlag = true;
      continue;
    }
    if (tok === "--") continue;
    if (tok.startsWith("-")) continue;
    return tok;
  }
  return null;
}

/**
 * True if cmd is `git branch -d|-D <branch>` AND the target branch is NOT
 * currently checked out in any worktree (per `git worktree list --porcelain`).
 *
 * Replaces the prior marker-based gate (#503): no marker file, no precondition
 * from /worktree-end — git's own registry is the source of truth.
 * Fail-closed: if `git worktree list` errors, the delete is blocked.
 */
function isAllowedBranchDeleteWhenNotCheckedOut(cmd, repoRoot) {
  if (hasShellChaining(cmd)) return false;
  const target = parseBranchDeleteTarget(cmd);
  if (!target) return false;
  if (!repoRoot) return false; // dispatch handles null repoRoot via early-allow
  let res;
  try {
    res = spawnSync("git", ["-C", repoRoot, "worktree", "list", "--porcelain"], {
      encoding: "utf8", timeout: 2000,
    });
  } catch (e) { return false; }
  if (!res || res.error || res.status !== 0) return false; // fail-closed
  const wanted = "branch refs/heads/" + target;
  const lines = (res.stdout || "").split(/\r?\n/);
  for (const ln of lines) {
    if (ln === wanted) return false; // currently checked out in some worktree
  }

  // Force-delete bypasses Git's merged-status check, so it must come from an
  // authorized skill (/worktree-end after PR merge). Authorization is the
  // inline cmd-string prefix `WORKTREE_END_SKILL=1`, matching the established
  // ISSUE_CLOSE_SKILL pattern: the hook inspects the raw command text, not
  // process.env (which Bash inline assignments do not populate in the hook's
  // process). The allowlist is tight — only the specific shape
  // `WORKTREE_END_SKILL=1 git -C <path> branch -D <branch>` qualifies.
  if (hasForceDeleteFlag(cmd)) {
    return isWorktreeEndSkillForceDelete(cmd);
  }
  return true;
}

// True if cmd is a branch-delete with any force form: -D, -f combined with -d,
// or --force. Combined short flags (-df, -Df, -fd) are detected as force.
// `-d` alone is the only non-force form.
function hasForceDeleteFlag(cmd) {
  const m = cmd.match(/\bbranch\b([^|;&]*)/);
  if (!m) return false;
  const tokens = [];
  const re = /"([^"]+)"|'([^']+)'|(\S+)/g;
  let mm;
  while ((mm = re.exec(m[1])) !== null) tokens.push(mm[1] || mm[2] || mm[3]);
  for (const tok of tokens) {
    if (tok === "--force") return true;
    if (/^-[a-zA-Z]+$/.test(tok)) {
      const flags = tok.slice(1);
      if (flags === "d") continue;
      if (/[Df]/.test(flags)) return true;
    }
  }
  return false;
}

// True if cmd matches the exact shape /worktree-end Step WE-18 emits:
//   WORKTREE_END_SKILL=1 git -C <path> branch -D <type>/<task-name>
// The -C path and branch may be quoted ("..." or '...') or bare. No shell
// chaining, no extra options. Branch name MUST match the feature-branch
// naming convention from rules/branch.md:
//   <type>/<name>  where type ∈ {feature, fix, refactor, docs, chore}
//                  and name ∈ [a-zA-Z0-9_-]+
// This is the sole authorized force-delete shape. Branches like `main`,
// `master`, `release/v2.0`, or any non-typed branch are rejected even with
// the inline prefix — defense-in-depth against bypass misuse.
function isWorktreeEndSkillForceDelete(cmd) {
  const m = cmd.match(
    /^WORKTREE_END_SKILL=1[ \t]+git[ \t]+-C[ \t]+(?:"[^"]+"|'[^']+'|\S+)[ \t]+branch[ \t]+-D[ \t]+(?:"([^"]+)"|'([^']+)'|(\S+))[ \t]*$/
  );
  if (!m) return false;
  const branch = m[1] || m[2] || m[3];
  return /^(?:feat|feature|fix|refactor|docs|chore)\/[a-zA-Z0-9_-]+$/.test(branch);
}

module.exports = {
  isBranchDeleteCommand,
  parseBranchDeleteTarget,
  isAllowedBranchDeleteWhenNotCheckedOut,
  hasForceDeleteFlag,
  isWorktreeEndSkillForceDelete,
};
