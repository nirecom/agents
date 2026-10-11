"use strict";
// hooks/enforce-worktree/main-worktree-allows/worktree-command.js
// isAllowedWorktreeCommand — allow predicate for `git worktree add/remove/prune`
// and PowerShell New-Item/ni (dispatched to ./new-item) from the main worktree.
// Extracted from standard.js (file-split per rules/coding/file-split.md Pattern A).

const { isPathOutsideRepo, rejectRceGitFlags, findFirstUnquotedAnd } = require("../shared-cmd-utils");
const { singleInvocation, cdTailInvocation, withoutWorktreeEndSkillPrefix, gitSubcommand, gitCDirIsRepo, redirectsUnderTmp } = require("./command-shape");
const { isAllowedNewItemCommand } = require("./new-item");

// Returns true if cmd is `git worktree remove` with --force or -f (short form).
// Tokenizes after "worktree remove" to avoid false positives from path components.
function hasWorktreeRemoveForceFlag(cmd) {
  const m = cmd.match(/\bworktree\s+remove\b(.*)/);
  if (!m) return false;
  const tokens = [];
  const re = /"([^"]+)"|'([^']+)'|(\S+)/g;
  let mm;
  while ((mm = re.exec(m[1])) !== null) tokens.push(mm[1] || mm[2] || mm[3]);
  return isForceRemove(tokens);
}

function isForceRemove(tokens) {
  return tokens.some((tok) => tok === "--force" || (/^-[a-zA-Z]+$/.test(tok) && tok.slice(1).includes("f")));
}

const ADD_FLAGS_WITH_VALUE = new Set(["-b", "-B", "--orphan", "--reason"]);

// First non-flag token of `worktree add`; `--` counts as a flag (--orphan=<b> is one token).
function addTargetPath(tokens) {
  for (let i = 0; i < tokens.length; i++) {
    if (!tokens[i].startsWith("-")) return tokens[i];
    if (ADD_FLAGS_WITH_VALUE.has(tokens[i])) i++;
  }
  return null;
}

/**
 * True if cmd is one `git worktree add/remove/prune` invocation whose add-target
 * path (when present) is outside repoRoot, or a New-Item/ni call ./new-item allows.
 * The only accepted second segment is the #982 worktree-start tail `&& cd <path>`
 * (cdTailInvocation), and the only accepted prefix is WORKTREE_END_SKILL=1 on git;
 * any other separator, nesting or prefix is rejected.
 */
function isAllowedWorktreeCommand(cmd, repoRoot) {
  const first = singleInvocation(cmd) || cdTailInvocation(cmd);
  const split = first && withoutWorktreeEndSkillPrefix(first);
  if (!split) return false;
  const { seg } = split;

  if (seg.cmd0 === "git") {
    if (rejectRceGitFlags(cmd) || !redirectsUnderTmp(seg)) return false;
    const git = gitSubcommand(seg);
    if (!git || git.sub !== "worktree" || !gitCDirIsRepo(git.cDirs, repoRoot)) return false;
    const action = git.rest[0];
    const args = git.rest.slice(1);
    if (action === "prune") return true;
    if (action === "remove") return !isForceRemove(args);
    if (action !== "add") return false;
    // Fail-open when path is absent (e.g. git worktree add -b foo — path omitted)
    const target = addTargetPath(args);
    return target ? isPathOutsideRepo(target, repoRoot) : true;
  }

  if (!split.skillPrefixed && /^(?:new-item|ni)$/i.test(seg.cmd0) && seg.cmd0Raw === seg.cmd0) {
    const andIdx = findFirstUnquotedAnd(cmd);
    const head = andIdx === -1 ? cmd : cmd.slice(0, andIdx).trim();
    return isAllowedNewItemCommand(head, repoRoot);
  }
  return false;
}

module.exports = { isAllowedWorktreeCommand, hasWorktreeRemoveForceFlag };
