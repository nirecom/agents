"use strict";

const path = require("path");
const { spawnSync } = require("child_process");
const { normalizeCwd } = require("../lib/path-normalize");
const { stripQuotedArgs } = require("../lib/strip-quoted-args");
const { hasShellChaining, isPathOutsideRepo, isExcluded, hasWorktreeEndSkillPrefix, stripWorktreeEndSkillPrefix } = require("./shared-cmd-utils");
const { parseGitCPath } = require("./git-repo-detection");

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
  if (/^\s*(?:[A-Z_][A-Z0-9_]*=\S*\s+)*\b(bash|sh|zsh|dash|pwsh|powershell|cmd|node|python|perl|ruby)\b/.test(cmd)) return false;
  if (hasShellChaining(cmd)) return false;
  if (!/\bgit\b/.test(cmd) || !/\bworktree\s+(?:add|remove|prune)\b/.test(cmd)) return false;

  const stripped = stripQuotedArgs(cmd);
  if (/[|;&]|\$\(|`/.test(stripped)) return false;

  // remove/prune do not create new checkout paths — always allow from main worktree
  if (/\bworktree\s+remove\b/.test(cmd) && hasWorktreeRemoveForceFlag(cmd)) return false;
  if (/\bworktree\s+(?:remove|prune)\b/.test(cmd)) return true;

  // For 'add': parse target path (first non-flag arg after 'add')
  const addMatch = cmd.match(/\bworktree\s+add\s+([\s\S]*)/);
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
}

/**
 * Returns true if cmd is an isolated `New-Item -ItemType Directory` command
 * whose target path is outside repoRoot.
 * Fails CLOSED (returns false) when no path can be parsed, to prevent
 * unverified in-repo directory creation.
 */
function isAllowedNewItemDirectory(cmd, repoRoot) {
  if (hasShellChaining(cmd)) return false;
  if (!/\bNew-Item\b/i.test(cmd)) return false;
  if (!/-ItemType\s+Directory\b/i.test(cmd)) return false;

  // Try named -Path/-p argument first
  const pathMatch = cmd.match(/-(?:Path|p)\s+(?:"([^"]+)"|'([^']+)'|(\S+))/i);
  if (pathMatch) {
    const targetPath = pathMatch[1] || pathMatch[2] || pathMatch[3];
    return targetPath ? isPathOutsideRepo(targetPath, repoRoot) : false;
  }

  // Positional path: first non-flag, non-flag-value token after New-Item
  const afterCmd = cmd.replace(/^.*?\bNew-Item\b\s*/i, "");
  const tokens = [];
  const re = /"([^"]+)"|'([^']+)'|(\S+)/g;
  let m;
  while ((m = re.exec(afterCmd)) !== null) tokens.push(m[1] || m[2] || m[3]);

  // PS flags that consume the next token as a value
  const flagsWithNextValue = new Set(["-itemtype", "-name", "-n", "-value", "-encoding"]);
  let skipNext = false;
  let targetPath = null;
  for (const tok of tokens) {
    if (skipNext) { skipNext = false; continue; }
    const key = tok.toLowerCase().replace(/^-+/, "-");
    if (tok.startsWith("-")) {
      if (flagsWithNextValue.has(key)) skipNext = true;
      continue;
    }
    targetPath = tok;
    break;
  }

  // Fail-closed: reject when path cannot be determined
  return targetPath ? isPathOutsideRepo(targetPath, repoRoot) : false;
}

/**
 * True if cmd is an isolated `git pull --ff-only` or `git merge --ff-only`
 * command. Allows the merge step from the main worktree — the one operation
 * main is reserved for ("Main worktree is reserved for merge/pull only").
 *
 * Blocks: shell chaining (`&& git push` etc.), `--no-ff` (overrides ff-only
 * intent), non-git tools (e.g. `svn merge --ff-only`), and `git rebase
 * --ff-only` (rebase is not merge).
 */
function isAllowedFastForwardMerge(cmd) {
  if (hasShellChaining(cmd)) return false;
  if (!/\bgit\b/.test(cmd)) return false;
  if (/\s--no-ff\b/.test(cmd)) return false;
  // Strict subcommand position: only flag tokens (and their values) may appear
  // between `git` and the `pull`/`merge` subcommand. This prevents false
  // matches like `git commit -m "merge --ff-only"` or `git push origin merge
  // --ff-only` where `merge` appears as an argument value rather than as the
  // subcommand. Pattern: `(?:-flag value? )*` then subcommand.
  const isPullFf  = /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*pull\b[^|;&]*\s--ff-only\b/.test(cmd);
  const isMergeFf = /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*merge\b[^|;&]*\s--ff-only\b/.test(cmd);
  return isPullFf || isMergeFf;
}

/**
 * True if cmd is an isolated `bash -c '...'` matching exactly the
 * read-only CONFIRM_* probe shape used by planning skills:
 *   bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off KEY on && echo OFF [|| echo ON]'
 *
 * Does NOT call hasShellChaining() — the probe body intentionally uses
 * && and || as control flow. Safety is enforced by structural clause matching.
 * Coupling: if the skill probe string changes, update this matcher in sync.
 * See docs/architecture/claude-code/workflow.md for the contract.
 */
function isAllowedReadOnlyConfigCheck(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const m = cmd.match(/^\s*bash\s+-c\s+(['"])([\s\S]+)\1\s*$/);
  if (!m) return false;
  const quote = m[1];
  let body = m[2];
  // Allow escaped same-quote inside body (e.g. `cd \"$AGENTS_CONFIG_DIR\"` when outer is `"`).
  // The clause regexes below are anchored, so any unescaped quote that breaks the
  // structure will be caught at the clause-match step.
  body = body.replace(quote === '"' ? /\\"/g : /\\'/g, quote);
  if (body.includes("`")) return false;
  if (body.includes("$(")) return false;
  if (body.includes(">") || body.includes("<")) return false;
  if (body.includes(";")) return false;
  if (body.replace(/\|\|/g, "").includes("|")) return false;
  const clauses = body.split(/\s*&&\s*/);
  if (clauses.length !== 3) return false;
  const [c1, c2, c3Raw] = clauses;
  const c3 = c3Raw.replace(/\s*\|\|\s*echo\s+ON\s*$/, "").trimEnd();
  if (!/^cd\s+(?:"?\$AGENTS_CONFIG_DIR"?)\s*$/.test(c1.trim())) return false;
  if (!/^get-config-var\s+--is-off\s+[A-Z][A-Z0-9_]*\s+(?:on|off)\s*$/.test(c2.trim())) return false;
  if (!/^echo\s+OFF\s*$/.test(c3.trim())) return false;
  return true;
}

/**
 * Resolve the upstream tracking ref for the current branch.
 * If remote is specified, only returns an upstream on that remote.
 */
function resolveUpstream(repoRoot, remote) {
  try {
    const branchRes = spawnSync("git", ["symbolic-ref", "--short", "HEAD"], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (branchRes.status !== 0) return null;
    const branch = (branchRes.stdout || "").trim();
    if (!branch) return null;
    const upRes = spawnSync("git", ["rev-parse", "--abbrev-ref", `${branch}@{upstream}`], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (upRes.status !== 0) return null;
    const upstream = (upRes.stdout || "").trim();
    if (!upstream) return null;
    if (remote && !upstream.startsWith(`${remote}/`)) return null;
    return upstream;
  } catch (e) { return null; }
}

/**
 * Allow `git push` from the main worktree when every file in every outgoing
 * commit is covered by ENFORCE_WORKTREE_EXCLUDE. Uses `git log --name-only`
 * to enumerate all touched files (not just net diff — a file touched then
 * reverted within the range still counts).
 * Fail-closed on unsupported refspec shapes, missing upstream, or git errors.
 */
function isAllowedPushAllExcluded(cmd, repoRoot, excludePatterns) {
  try {
    if (!excludePatterns || excludePatterns.length === 0) return false;
    if (hasShellChaining(cmd)) return false;
    if (!/\bgit\b.*\bpush\b/.test(cmd)) return false;

    const stripped = stripQuotedArgs(cmd);
    const tokens = stripped.trim().split(/\s+/);
    const pushIdx = tokens.findIndex((t) => t === "push");
    if (pushIdx === -1) return false;

    const KNOWN_FLAGS = new Set([
      "-q", "--quiet", "-v", "--verbose",
      "--porcelain", "-n", "--dry-run", "--atomic",
    ]);
    const UPSTREAM_FLAGS = new Set(["-u", "--set-upstream"]);
    const positionals = [];
    let sawUpstreamFlag = false;
    for (const t of tokens.slice(pushIdx + 1)) {
      if (UPSTREAM_FLAGS.has(t)) { sawUpstreamFlag = true; continue; }
      if (KNOWN_FLAGS.has(t)) continue;
      if (t.startsWith("-")) return false; // unknown flag → fail-closed
      positionals.push(t);
    }
    // -u/--set-upstream requires an explicit <remote> <branch> — fail-closed otherwise
    if (sawUpstreamFlag && positionals.length !== 2) return false;

    let upstreamRef;
    if (positionals.length === 0) {
      upstreamRef = resolveUpstream(repoRoot);
    } else if (positionals.length === 1) {
      upstreamRef = resolveUpstream(repoRoot, positionals[0]);
    } else if (positionals.length === 2) {
      const [remote, branch] = positionals;
      if (branch.includes(":") || branch.startsWith("refs/") || branch.startsWith("+")) return false;
      if (!/^[A-Za-z0-9._\/-]+$/.test(branch)) return false;
      const checkRes = spawnSync("git", ["rev-parse", "--verify", `${remote}/${branch}`], {
        cwd: repoRoot, timeout: 2000,
      });
      if (checkRes.status !== 0) return false;
      upstreamRef = `${remote}/${branch}`;
    } else {
      return false; // multiple refspecs → fail-closed
    }
    if (!upstreamRef) return false;

    const logRes = spawnSync(
      "git", ["log", "--name-only", "--pretty=format:", `${upstreamRef}..HEAD`],
      { cwd: repoRoot, encoding: "utf8", timeout: 10000 }
    );
    if (logRes.status !== 0) return false;

    // Anchor relative paths from git log against repoRoot (not process.cwd):
    // isExcluded internally calls path.resolve which would otherwise resolve
    // against the hook's cwd, mis-matching absolute-style EXCLUDE patterns.
    const files = (logRes.stdout || "")
      .split("\n")
      .map((f) => f.trim())
      .filter(Boolean)
      .map((f) => path.resolve(repoRoot, normalizeCwd(f) || f));
    if (files.length === 0) return true; // no outgoing commits → allow
    return files.every((f) => isExcluded(f, excludePatterns));
  } catch (e) { return false; }
}

/**
 * True when cmd is an approved cleanup-class git command AND no linked
 * worktrees remain (confirming cleanup has completed).
 *
 * Approved commands (issue #297):
 *   git [-C <repoRoot>] stash (push|pop|apply|drop|clear) [...]
 *   git [-C <repoRoot>] restore [--staged] <paths>        — no --source
 *   git [-C <repoRoot>] checkout -- <paths>               — `--` required; no -b/-B/-f
 *   git [-C <repoRoot>] checkout HEAD -- <paths>          — same
 *
 * Hard restrictions:
 *   - hasShellChaining → reject
 *   - -C flag, if present, must resolve to repoRoot (not another repo)
 *   - checkout: only path-restore forms (requires `--` separator; no branch flags)
 *   - stash: only push|pop|apply|drop|clear (not branch|show|store|create|list)
 *   - restore: no --source (would rewrite from arbitrary tree)
 *   - Linked-worktrees probe: spawnSync git worktree list --porcelain must return
 *     exactly 1 entry. Fail-closed on git error.
 */
function isAllowedMainWorktreeCleanup(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  if (!repoRoot) return false;
  const skillPrefixed = hasWorktreeEndSkillPrefix(cmd);
  if (skillPrefixed) cmd = stripWorktreeEndSkillPrefix(cmd);
  if (hasShellChaining(cmd)) return false;
  if (!/\bgit\b/.test(cmd)) return false;

  // -C path, if present, must resolve to repoRoot.
  // Reject multiple -C flags — parseGitCPath only validates the first;
  // git uses the last (or cumulative), creating an ambiguity gap.
  if ((cmd.match(/\s-C\s/g) || []).length > 1) return false;
  if (/\s-C\s/.test(stripQuotedArgs(cmd))) {
    const cArg = parseGitCPath(cmd);
    if (!cArg) return false;
    try {
      const normC    = normalizeCwd(cArg)    || cArg;
      const normBase = normalizeCwd(repoRoot) || repoRoot;
      if (path.resolve(normC).toLowerCase() !== path.resolve(normBase).toLowerCase()) return false;
    } catch (e) { return false; }
  }

  // Find the git subcommand (skip `git`, optional `-C <path>`, optional global flags).
  const stripped = stripQuotedArgs(cmd);
  const subMatch = stripped.match(
    /\bgit\b(?:\s+-C\s+\S+)?(?:\s+-\S+(?:\s+\S+)?)*\s+(stash|restore|checkout)\b([\s\S]*)$/
  );
  if (!subMatch) return false;
  const sub  = subMatch[1];
  const rest = subMatch[2] || "";

  if (sub === "stash") {
    const firstToken = rest.trim().split(/\s+/)[0] || "";
    const ALLOWED_STASH = new Set(["", "push", "pop", "apply", "drop", "clear"]);
    // A leading `-` flag is a push modifier (e.g. `git stash -u`) — allowed.
    if (!ALLOWED_STASH.has(firstToken) && !firstToken.startsWith("-")) return false;
  } else if (sub === "restore") {
    if (/\s--source(?:=|\s)/.test(cmd)) return false;
  } else { // checkout
    // Path-restore form: requires `--` separator before the file paths.
    if (!/\s--(?:\s|$)/.test(rest)) return false;
    // Reject branch-creation flags before the `--`.
    const beforeSep = rest.split(/\s--(?:\s|$)/)[0] || "";
    if (/(^|\s)-[bBf](\s|$)/.test(beforeSep)) return false;
    // Allow only no-token-before-`--` (→ `git checkout -- <paths>`) or
    // exactly `HEAD` before `--` (→ `git checkout HEAD -- <paths>`).
    const before = beforeSep.trim();
    if (before !== "" && before !== "HEAD") return false;
  }

  // Runtime gate: no linked worktrees remain.
  try {
    const r = spawnSync("git", ["worktree", "list", "--porcelain"], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return false;
    const wtCount = ((r.stdout || "").match(/^worktree\s/gm) || []).length;
    const maxCount = skillPrefixed ? 2 : 1;
    return wtCount >= 1 && wtCount <= maxCount;
  } catch (e) { return false; }
}

module.exports = {
  isAllowedWorktreeCommand,
  isAllowedNewItemDirectory,
  isAllowedFastForwardMerge,
  isAllowedReadOnlyConfigCheck,
  isAllowedPushAllExcluded,
  isAllowedMainWorktreeCleanup,
};
