"use strict";
// hooks/enforce-worktree/main-worktree-allows/worktree-command.js
// isAllowedWorktreeCommand — allow predicate for `git worktree add/remove/prune`
// and PowerShell New-Item/ni (dispatched to ./new-item) from the main worktree.
// Extracted from standard.js (file-split per rules/coding/file-split.md Pattern A).

const path = require("path");
const { normalizeCwd } = require("../../lib/path-normalize");
const { stripQuotedArgs } = require("../../lib/strip-quoted-args");
const { hasShellChaining, isPathOutsideRepo, rejectInterpreterAndChaining, findFirstUnquotedAnd } = require("../shared-cmd-utils");
const { parseGitCPath } = require("../git-repo-detection");
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
  for (const tok of tokens) {
    if (tok === "--force") return true;
    if (/^-[a-zA-Z]+$/.test(tok) && tok.slice(1).includes("f")) return true;
  }
  return false;
}

/**
 * Returns true if cmd is an isolated `git worktree add/remove/prune` command
 * whose add-target path (when parseable) is outside repoRoot.
 *
 * Flags for `git worktree add` that consume the next space-separated token:
 *   -b <branch>  -B <branch>  --orphan <branch>
 * (--orphan=<branch> uses = syntax and is a single token — handled correctly.)
 * `--` (end-of-options) is treated as a flag and skipped; the next token is path.
 */
function isAllowedWorktreeCommand(cmd, repoRoot) {
  // Split off a trailing `&& cd <path>` (the sanctioned worktree-start shape)
  // before the chaining guards, then evaluate the guards against `head` only.
  // The cd tail must be a bare `cd <single-path>` — no further chaining,
  // interpreter invocation, or command substitution (#982, #838).
  const andIdx = findFirstUnquotedAnd(cmd);
  let head = cmd;
  if (andIdx !== -1) {
    head = cmd.slice(0, andIdx).trim();
    const tail = cmd.slice(andIdx + 2).trim();
    if (tail !== "") {
      if (!/^cd\s+(?:"[^"$`]+"|'[^']+'|[^\s$`;|&<>()]+)\s*$/.test(tail)) return false;
      if (hasShellChaining(tail)) return false;
      if (rejectInterpreterAndChaining(tail)) return false;
    }
  }

  if (rejectInterpreterAndChaining(head)) return false;
  if (hasShellChaining(head)) return false;

  const stripped = stripQuotedArgs(head);

  // Head-first dispatch: git worktree branch vs New-Item/ni branch vs reject.
  if (/\bgit\b/.test(stripped) && /\bworktree\s+(?:add|remove|prune)\b/.test(stripped)) {
    // ── git worktree branch ──────────────────────────────────────────────────
    // Multiple -C flags → reject (parseGitCPath only reads the first).
    if ((head.match(/\s-C\s/g) || []).length > 1) return false;
    if (/\s-C\s/.test(stripped)) {
      const cArg = parseGitCPath(head);
      if (!cArg) return false;
      try {
        const normC    = normalizeCwd(cArg)    || cArg;
        const normBase = normalizeCwd(repoRoot) || repoRoot;
        if (path.resolve(normC).toLowerCase() !== path.resolve(normBase).toLowerCase()) return false;
      } catch (e) { return false; }
    }

    // remove/prune do not create new checkout paths — always allow from main worktree
    if (/\bworktree\s+remove\b/.test(stripped) && hasWorktreeRemoveForceFlag(head)) return false;
    if (/\bworktree\s+(?:remove|prune)\b/.test(stripped)) return true;

    // For 'add': parse target path (first non-flag arg after 'add')
    const addMatch = head.match(/\bworktree\s+add\s+([\s\S]*)/);
    if (!addMatch) return true; // can't parse — fail-open

    const tokens = [];
    const re = /"([^"]+)"|'([^']+)'|(\S+)/g;
    let m;
    while ((m = re.exec(addMatch[1])) !== null) tokens.push(m[1] || m[2] || m[3]);

    const flagsWithNextValue = new Set(["-b", "-B", "--orphan"]);
    let skipNext = false;
    let targetPath = null;
    for (const tok of tokens) {
      if (skipNext) { skipNext = false; continue; }
      if (tok.startsWith("-")) {
        if (flagsWithNextValue.has(tok)) skipNext = true;
        continue;
      }
      targetPath = tok;
      break;
    }

    // Fail-open when path is absent (e.g. git worktree add -b foo — path omitted)
    return targetPath ? isPathOutsideRepo(targetPath, repoRoot) : true;

  } else if (/^\s*(?:new-item|ni)\b/i.test(stripped)) {
    // ── New-Item / ni branch: delegate to dedicated module (file-split per rules/coding/file-split.md).
    // Head-anchored (F2): only dispatch when New-Item/ni is the command head, not embedded
    // anywhere in the command (e.g. `somecmd ni -ItemType Directory ...` must NOT reach here).
    return isAllowedNewItemCommand(head, repoRoot);

  } else {
    return false;
  }
}

module.exports = { isAllowedWorktreeCommand, hasWorktreeRemoveForceFlag };
