#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce worktree-based parallel session workflow.
//
// Scope:
//   Blocks Edit/Write/MultiEdit/Bash write operations when:
//     1. Running in the main git checkout (not a linked worktree), regardless of branch.
//     2. Running on a protected branch even inside a linked worktree.
//   Allows writes only from a linked worktree on a non-protected branch.
//
// Main worktree detection:
//   git rev-parse --git-common-dir == git rev-parse --git-dir
//   (Linked worktrees have --git-common-dir pointing to the shared .git while --git-dir
//   points to .git/worktrees/<name> — they differ only in linked worktrees.)
//
// Bash detection:
//   - Parses git -C <path> from command string (best-effort regex) for target repo root.
//   - Falls back to process.cwd() when no -C is found.
//   - Only write-classified commands are checked (see hooks/lib/bash-write-patterns.js).
//   - gh write commands (kind:"gh" in WRITE_PATTERNS) get an additional
//     session-scope check: target repo must be in CWD repo + ENFORCE_WORKTREE_EXTRA_REPOS.
//
// Limitations (documented; this is a UX guard, not a security boundary):
//   - Bash write detection is pattern-based. Python/binary/runtime-expanded writes not caught.
//   - Redirect targets outside cwd are not detected.
//   - Use ENFORCE_WORKTREE=off to bypass for trivial direct-main work.
//
// --- BEGIN temporary: AGENT_AUTO_BRANCH → ENFORCE_WORKTREE migration ---
// AGENT_AUTO_BRANCH and AGENT_DEFAULT_BRANCHES are accepted with a deprecation warning.
// Remove this block once all agents configs have been updated.
// --- END temporary: AGENT_AUTO_BRANCH → ENFORCE_WORKTREE migration ---

"use strict";

const fs = require("fs");
const os = require("os");
const { spawnSync } = require("child_process");
const path = require("path");

try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { normalizeCwd } = require("./lib/path-normalize");
const { stripQuotedArgs } = require("./lib/strip-quoted-args");
const { WRITE_PATTERNS, classify } = require("./lib/bash-write-patterns");
const { parseExcludePatterns, matchesAnyExcludePattern } = require("./lib/glob-match");
const {
  extractRedirectTargets, extractTeeTargets,
  extractPwshWriteTargets, extractCpMvDestination,
  extractStagedFiles,
} = require("./lib/bash-write-targets");

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch (e) {
    return "";
  }
}

function isEnforceWorktreeOn() {
  let raw = process.env.ENFORCE_WORKTREE;
  if (raw === undefined || raw === null) {
    const legacy = process.env.AGENT_AUTO_BRANCH;
    if (legacy !== undefined && legacy !== null) {
      process.stderr.write(
        "enforce-worktree: AGENT_AUTO_BRANCH is deprecated; rename to ENFORCE_WORKTREE in agents config.\n"
      );
      raw = legacy;
    }
  }
  // No trim — whitespace-padded values are unknown and default ON (fail-safe block)
  const v = (raw || "").toLowerCase();
  // Default ON — only OFF when explicitly set to a recognised falsy value
  return !["off", "0", "false", "no", "disabled"].includes(v);
}

function getProtectedBranches(repoCwd) {
  // Prefer DEFAULT_BRANCHES; fall back to AGENT_DEFAULT_BRANCHES for migration.
  let override = (process.env.DEFAULT_BRANCHES || "").trim();
  if (!override && process.env.AGENT_DEFAULT_BRANCHES) {
    process.stderr.write(
      "enforce-worktree: AGENT_DEFAULT_BRANCHES is deprecated; rename to DEFAULT_BRANCHES in agents config.\n"
    );
    override = (process.env.AGENT_DEFAULT_BRANCHES || "").trim();
  }
  if (override) {
    return override.split(",").map((s) => s.trim()).filter(Boolean);
  }

  const branches = new Set();
  try {
    const r = spawnSync("git", ["symbolic-ref", "refs/remotes/origin/HEAD"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    if (r.status === 0) {
      const m = (r.stdout || "").trim().match(/refs\/remotes\/origin\/(.+)$/);
      if (m) branches.add(m[1]);
    }
  } catch (e) {}
  for (const c of ["main", "master"]) {
    try {
      const r = spawnSync("git", ["show-ref", "--verify", "--quiet", `refs/heads/${c}`], {
        cwd: repoCwd, timeout: 2000,
      });
      if (r.status === 0) branches.add(c);
    } catch (e) {}
  }
  try {
    const r = spawnSync("git", ["config", "init.defaultBranch"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    if (r.status === 0) { const v = (r.stdout || "").trim(); if (v) branches.add(v); }
  } catch (e) {}
  if (branches.size === 0) branches.add("main");
  return [...branches];
}

function getCurrentBranch(repoCwd) {
  try {
    const verify = spawnSync("git", ["rev-parse", "--verify", "HEAD"], { cwd: repoCwd, timeout: 2000 });
    if (verify.status !== 0) return null; // unborn HEAD
    const r = spawnSync("git", ["symbolic-ref", "--short", "HEAD"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null; // detached HEAD
    return (r.stdout || "").trim() || null;
  } catch (e) {
    return null;
  }
}

/** True if cmd contains shell chaining/pipe operators outside of quotes.
 *  Also rejects command substitutions ($() and backticks): those spawn a
 *  shell that runs the inner command, which is effectively chaining for
 *  exemption-allowance purposes. Without this, `git merge --ff-only $(rm -rf
 *  /)` would slip past the chaining guard.
 *  Note: bare `&` also matches PowerShell's call operator (& git.exe ...),
 *  so `& git.exe worktree add` is conservatively rejected. */
function hasShellChaining(cmd) {
  const stripped = stripQuotedArgs(cmd);
  return /[|;&]|\$\(|`/.test(stripped);
}

// True when cmd contains command-sequencing operators (;, &&, ||) outside quotes.
// Single | (pipe) is excluded — needed for `cmd | tee file`. &> (redirect) is
// not matched because the regex requires two & characters for &&.
// Commands with sequencing must not be fast-pathed through the session-scope
// allow: the un-extracted portion may contain in-scope writes (e.g. rm, mv).
function hasCommandSequencing(cmd) {
  const stripped = stripQuotedArgs(cmd);
  return /;|&&|\|\|/.test(stripped);
}

/**
 * True when targetPath resolves to a location OUTSIDE repoRoot.
 * Relative paths are resolved against process.cwd() (the main worktree when
 * this hook runs), which gives the correct semantic for worktree paths.
 * Fails open (returns true) when the path cannot be resolved.
 */
function isPathOutsideRepo(targetPath, repoRoot) {
  try {
    // Normalize POSIX drive-letter paths (e.g. /c/git/foo) to Windows native
    // form before path.resolve, which on Windows otherwise misresolves them
    // to C:\c\git\foo. No-op on non-Windows and on already-native paths.
    const normTarget = normalizeCwd(targetPath) || targetPath;
    const normBase = normalizeCwd(repoRoot) || repoRoot;
    const resolved = path.resolve(normTarget).toLowerCase();
    const base = path.resolve(normBase).toLowerCase();
    return resolved !== base &&
           !resolved.startsWith(base + path.sep) &&
           !resolved.startsWith(base + "/");
  } catch (e) {
    return true; // fail-open
  }
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
  if (hasShellChaining(cmd)) return false;
  if (!/\bgit\b/.test(cmd) || !/\bworktree\s+(?:add|remove|prune)\b/.test(cmd)) return false;

  // remove/prune do not create new checkout paths — always allow from main worktree
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

// Resolve WORKTREE_BASE_DIR with ~ expansion and a default of ~/git/worktrees.
// Per rules/worktree.md, this is the parent directory all linked worktrees live under.
function getWorktreeBaseDir() {
  const raw = (process.env.WORKTREE_BASE_DIR || "").trim();
  const baseRaw = raw || path.join(os.homedir(), "git", "worktrees");
  const expanded = baseRaw.startsWith("~")
    ? path.join(os.homedir(), baseRaw.slice(1).replace(/^[\/\\]/, ""))
    : baseRaw;
  return path.resolve(expanded);
}

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
 * True if cmd is `git branch -d|-D <branch>` AND a marker file produced by
 * /worktree-end authorises this exact deletion.
 *
 * Marker contract (written by /worktree-end before `git worktree remove`):
 *   path:    <git-common-dir>/info/pending-branch-delete
 *   format:  line 1 = target branch name
 *            line 2 = absolute path of the worktree being removed
 *
 * Both must match: branch name == target, worktree path resolves under
 * WORKTREE_BASE_DIR. This narrows the exemption to /worktree-end-driven
 * cleanups; ad-hoc `git branch -D` from any worktree is still blocked.
 *
 * The marker lives in the SHARED .git directory (git-common-dir), so it is
 * readable from both the main worktree and any linked worktree.
 */
function isAllowedBranchDeleteViaMarker(cmd, repoRoot) {
  if (hasShellChaining(cmd)) return false;
  const target = parseBranchDeleteTarget(cmd);
  if (!target) return false;
  if (!repoRoot) return false;

  let commonDir;
  try {
    const r = spawnSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return false;
    commonDir = path.resolve(repoRoot, (r.stdout || "").trim());
  } catch (e) { return false; }

  const markerPath = path.join(commonDir, "info", "pending-branch-delete");
  let content;
  try { content = fs.readFileSync(markerPath, "utf8"); }
  catch (e) { return false; }

  const lines = content.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length < 2) return false;
  const markerBranch = lines[0];
  const markerWorktreePath = lines[1];

  if (markerBranch !== target) return false;

  const baseDir = getWorktreeBaseDir();
  const norm = (p) => {
    try {
      const n = normalizeCwd(p) || p;
      const r = path.resolve(n);
      return process.platform === "win32" ? r.toLowerCase() : r;
    } catch (e) { return null; }
  };
  const nBase = norm(baseDir);
  const nWtree = norm(markerWorktreePath);
  if (!nBase || !nWtree) return false;

  return nWtree === nBase ||
         nWtree.startsWith(nBase + path.sep) ||
         nWtree.startsWith(nBase + "/");
}

function extractRemoveItemPositionals(afterCmd) {
  const results = [];
  const re = /"([^"]+)"|'([^']+)'|(\S+)/g;
  let m;
  let consumeAsTarget = false;
  while ((m = re.exec(afterCmd)) !== null) {
    const tok = m[1] !== undefined ? m[1] : (m[2] !== undefined ? m[2] : m[3]);
    if (consumeAsTarget) {
      const v = tok.replace(/^["']|["']$/g, "").trim();
      if (v) results.push(v);
      consumeAsTarget = false;
      continue;
    }
    if (/^-(?:Path|LiteralPath)$/i.test(tok)) { consumeAsTarget = true; continue; }
    if (tok.startsWith("-")) continue;
    tok.split(",").map((s) => s.replace(/^["']|["']$/g, "").trim()).filter(Boolean)
      .forEach((v) => results.push(v));
  }
  return results;
}

// True if cmd is an isolated delete of the pending-branch-delete marker file
// AND the branch recorded in the marker no longer exists in repoRoot.
// /worktree-end Step 6g must remove the marker after Step 6f deletes the branch.
// CWD may have reset to main worktree on Windows after Step 6c (worktree remove),
// so the delete needs an explicit main-worktree exception.
// Fail-closed on any unexpected input, multi-target invocation, or non-1 git exit.
function isAllowedMarkerDelete(cmd, repoRoot) {
  if (hasShellChaining(cmd)) return false;
  if (!repoRoot) return false;
  const isRm = /^\s*rm(?:\s|$)/.test(cmd);
  const isRemoveItem = /^\s*Remove-Item(?:\s|$)/i.test(cmd);
  if (!isRm && !isRemoveItem) return false;
  // Reject recursive flags: POSIX -r/-R/-rf; PowerShell -Recurse and all prefix abbreviations.
  if (isRm && (/(?:^|\s)-[a-zA-Z]*[rR]/.test(cmd) || /(?:^|\s)--recursive\b/.test(cmd))) return false;
  if (isRemoveItem && /(?:^|\s)-(?:r|re|rec|recu|recur|recurs|recurse)\b/i.test(cmd)) return false;
  // Only -LiteralPath is allowed for PowerShell; -Path uses wildcard semantics.
  if (isRemoveItem && /-Path\b/i.test(cmd) && !/-LiteralPath\b/i.test(cmd)) return false;
  // Resolve the marker path.
  let commonDir;
  try {
    const r = spawnSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return false;
    commonDir = path.resolve(repoRoot, (r.stdout || "").trim());
  } catch (e) { return false; }
  const markerPath = path.join(commonDir, "info", "pending-branch-delete");
  // Extract all positional targets; require exactly one.
  let positionals = [];
  if (isRemoveItem) {
    const after = cmd.replace(/^\s*Remove-Item\s*/i, "");
    positionals = extractRemoveItemPositionals(after);
  } else {
    const after = cmd.replace(/^\s*rm\s*/, "");
    const tokens = [];
    const re = /"([^"]+)"|'([^']+)'|(\S+)/g;
    let m;
    while ((m = re.exec(after)) !== null)
      tokens.push(m[1] !== undefined ? m[1] : (m[2] !== undefined ? m[2] : m[3]));
    positionals = tokens.filter((t) => !t.startsWith("-"));
  }
  if (positionals.length !== 1) return false;
  const target = positionals[0];
  const norm = (p) => {
    try {
      const n = normalizeCwd(p) || p;
      const r = path.resolve(n);
      return process.platform === "win32" ? r.toLowerCase() : r;
    } catch (e) { return null; }
  };
  const nTarget = norm(target);
  const nMarker = norm(markerPath);
  if (!nTarget || !nMarker || nTarget !== nMarker) return false;
  // Read marker. ENOENT → file is absent, allow deletion as a no-op (handles
  // manual cleanup of stale markers from aborted /worktree-end runs).
  // Any other error is unexpected → fail-closed.
  let content;
  try { content = fs.readFileSync(markerPath, "utf8"); }
  catch (e) { return e.code === "ENOENT"; }
  const lines = content.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length < 1) return false;
  const markerBranch = lines[0];
  // Branch-existence check: status 0 = exists (block), 1 = not found (allow), ≥2 = fatal (fail-closed).
  try {
    const r = spawnSync(
      "git", ["show-ref", "--verify", "--quiet", `refs/heads/${markerBranch}`],
      { cwd: repoRoot, timeout: 2000 }
    );
    if (r.error) return false;
    if (r.status === null) return false;
    if (r.status !== 1) return false;
  } catch (e) { return false; }
  return true;
}

/**
 * True if filePath resolves to the pending-branch-delete marker at
 * <git-common-dir>/info/pending-branch-delete for the given repoRoot.
 * Allows Write/Edit tool calls to the marker from the main worktree:
 * /worktree-end writes this file before calling git branch -d.
 */
function isMarkerFilePath(filePath, repoRoot) {
  if (!filePath || !repoRoot) return false;
  let commonDir;
  try {
    const r = spawnSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return false;
    commonDir = path.resolve(repoRoot, (r.stdout || "").trim());
  } catch (e) { return false; }
  const markerPath = path.join(commonDir, "info", "pending-branch-delete");
  const norm = (p) => {
    try {
      const n = normalizeCwd(p) || p;
      const r = path.resolve(n);
      return process.platform === "win32" ? r.toLowerCase() : r;
    } catch (e) { return null; }
  };
  const nTarget = norm(filePath);
  const nMarker = norm(markerPath);
  return !!(nTarget && nMarker && nTarget === nMarker);
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

// Returns true when repoCwd is the main worktree (non-linked).
// In a linked worktree, --git-common-dir and --git-dir differ.
function isMainCheckout(repoCwd) {
  try {
    const common = spawnSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    const gitDir = spawnSync("git", ["rev-parse", "--git-dir"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    if (common.status !== 0 || gitDir.status !== 0) return false;
    const c = path.resolve(repoCwd, (common.stdout || "").trim());
    const g = path.resolve(repoCwd, (gitDir.stdout || "").trim());
    return c.toLowerCase() === g.toLowerCase();
  } catch (e) {
    return false;
  }
}

// Parse git -C <path> from a command string (best-effort, not a full shell parser).
// Handles: git -C /path, git -C "/path with spaces", git -C 'path', git --work-tree=... -C path
function parseGitCPath(cmd) {
  const m = cmd.match(/\bgit\b(?:\s+-\S+)*\s+-C\s+(?:"([^"]+)"|'([^']+)'|(\S+))/);
  if (!m) return null;
  const raw = m[1] || m[2] || m[3];
  if (!raw) return null;
  // Normalize Unix-style drive paths (Git Bash): /c/path → C:\path
  const driveMatch = raw.match(/^\/([a-zA-Z])(\/.*)?$/);
  if (driveMatch) {
    return driveMatch[1].toUpperCase() + ":\\" +
      (driveMatch[2] || "").replace(/\//g, "\\").replace(/^\\/, "");
  }
  // Normalize Windows forward slashes: c:/path → c:\path
  if (process.platform === "win32" && /^[a-zA-Z]:\//.test(raw)) return raw.replace(/\//g, "\\");
  return raw;
}

function findRepoRootForBash(cmd) {
  const cArg = parseGitCPath(cmd);
  const startDir = cArg || process.cwd();
  try {
    const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: startDir, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null;
    return (r.stdout || "").trim() || null;
  } catch (e) {
    return null;
  }
}

// Normalize a path for case-aware comparison.
// Windows: case-insensitive (FS is case-insensitive); POSIX: case-sensitive.
function normalizeForCompare(p) {
  try {
    const resolved = path.resolve(p);
    return process.platform === "win32" ? resolved.toLowerCase() : resolved;
  } catch (e) {
    return null;
  }
}

// Resolve a directory to its containing git repo root, with normalization for compare.
function resolveRepoRoot(startDir) {
  try {
    const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: startDir, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null;
    const out = (r.stdout || "").trim();
    return out ? normalizeForCompare(out) : null;
  } catch (e) {
    return null;
  }
}

// Returns the set of repo roots considered "in session scope" for gh write commands.
// Composition:
//   - process.cwd() repo root (always included if it resolves to a repo)
//   - Each path listed in ENFORCE_WORKTREE_EXTRA_REPOS (semicolon-separated)
// Behaviour:
//   - Whitespace around entries is trimmed; empty entries are skipped.
//   - Nonexistent paths are silently skipped (not an error).
//   - Paths are passed to git rev-parse via cwd — never to a shell — so
//     metacharacters in env values cannot be exec'd.
function getSessionRepoRoots() {
  const roots = new Set();
  const cwdRoot = resolveRepoRoot(process.cwd());
  if (cwdRoot) roots.add(cwdRoot);
  const extra = (process.env.ENFORCE_WORKTREE_EXTRA_REPOS || "")
    .split(";").map((s) => s.trim()).filter(Boolean);
  for (const dir of extra) {
    let resolved;
    try { resolved = path.resolve(dir); } catch (e) { continue; }
    if (!fs.existsSync(resolved)) continue;
    const root = resolveRepoRoot(resolved);
    if (root) {
      roots.add(root);
    } else {
      // Not a git repo itself — scan immediate subdirectories (depth 1).
      try {
        for (const entry of fs.readdirSync(resolved, { withFileTypes: true })) {
          if (!entry.isDirectory()) continue;
          const sub = resolveRepoRoot(path.join(resolved, entry.name));
          if (sub) roots.add(sub);
        }
      } catch (e) { /* skip non-readable dirs */ }
    }
  }
  return roots;
}

function getExcludePatterns() {
  return parseExcludePatterns(process.env.ENFORCE_WORKTREE_EXCLUDE || "");
}

function isExcluded(filePath, patterns) {
  if (!patterns || patterns.length === 0) return false;
  if (!filePath || typeof filePath !== "string") return false;
  try {
    const norm = normalizeCwd(filePath) || filePath;
    const abs = path.resolve(norm);
    // Full-path match (patterns containing '/' or '**').
    if (matchesAnyExcludePattern(abs, patterns)) return true;
    // Gitignore semantics: patterns without '/' also match against basename.
    const basenamePatterns = patterns.filter((p) => !p.includes("/"));
    if (basenamePatterns.length === 0) return false;
    return matchesAnyExcludePattern(path.basename(abs), basenamePatterns);
  } catch (e) { return false; }
}

function isInSessionScope(repoRoot, sessionRoots) {
  if (!repoRoot) return false;
  const norm = normalizeForCompare(repoRoot);
  return norm ? sessionRoots.has(norm) : false;
}

// Collect write targets from all applicable extractors (redirect, tee, PS cmdlets).
// Any extractor returning null → parseFailure = true (fail-closed).
function collectBashWriteTargets(cmd) {
  const targets = [];
  let parseFailure = false;

  if (/(?:^|[\s;|&])(?:\d*)(?:&>>?|>>?)(?!>|\d)/.test(cmd)) {
    const r = extractRedirectTargets(cmd);
    if (r === null) parseFailure = true;
    else targets.push(...r);
  }
  if (/(?:^|[\s;|&])tee\b/.test(cmd)) {
    const t = extractTeeTargets(cmd);
    if (t === null) parseFailure = true;
    else targets.push(...t);
  }
  if (/\b(?:Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item)\b/i.test(cmd)
      || /(?:^|[\s;|&])(?:sc|ac|ni|ri|mi|ci)\b/.test(cmd)) {
    const p = extractPwshWriteTargets(cmd);
    if (p === null) parseFailure = true;
    else targets.push(...p);
  }
  if (/(?:^|[\s;|&])(?:cp|mv)\b/.test(cmd)) {
    const d = extractCpMvDestination(cmd);
    if (d === null) parseFailure = true;
    else targets.push(d);
  }

  return { targets: targets.length > 0 ? targets : null, parseFailure };
}

// True if all targets resolve to repos outside the session scope.
// findRepoRoot()==null (non-git path) is also treated as outside scope (allow).
function areAllBashTargetsOutsideSessionScope(targets, sessionRoots) {
  if (!targets || targets.length === 0) return false;
  for (const t of targets) {
    const repo = findRepoRoot(t);
    if (repo !== null && isInSessionScope(repo, sessionRoots)) return false;
  }
  return true;
}

// EXCLUDE check for file-target writes and git commit (staged files).
function isWriteTargetAllExcluded(cmd, targets, repoRoot, patterns) {
  if (!patterns || patterns.length === 0) return false;
  const isGitCommit = /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*commit\b/.test(cmd);

  if (isGitCommit) {
    const staged = extractStagedFiles(repoRoot);
    if (staged === null || staged.length === 0) return false;
    if (!staged.every((f) => isExcluded(f, patterns))) return false;
  }

  if (targets) {
    if (!targets.every((f) => isExcluded(f, patterns))) return false;
  }

  return isGitCommit || (targets !== null && targets.length > 0);
}

// True if cmd matches any kind:"gh" entry in WRITE_PATTERNS (= Group B gh writes).
function isGhWriteCommand(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  for (const p of WRITE_PATTERNS) {
    if (p.kind === "gh" && p.regex.test(cmd)) return true;
  }
  return false;
}

function findRepoRoot(filePath) {
  let dir;
  try {
    const normalized = normalizeCwd(filePath) || filePath;
    dir = path.dirname(path.resolve(normalized));
  } catch (e) {
    return null;
  }
  try {
    const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: dir, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null;
    return (r.stdout || "").trim() || null;
  } catch (e) {
    return null;
  }
}

function done(decision) {
  if (decision && decision.block) {
    console.log(JSON.stringify({ decision: "block", reason: decision.reason }));
  } else {
    console.log(JSON.stringify({}));
  }
  process.exit(0);
}

// ── Main ──────────────────────────────────────────────────────────────────────
// Wrapped in `if (require.main === module)` so the file can be `require()`d
// from tests without executing the CLI flow (which reads stdin and exits).

if (require.main === module) {

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  done(); // fail-open on malformed stdin
}

if (!isEnforceWorktreeOn()) done();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

let repoRoot = null;

if (toolName === "Bash") {
  const cmd = toolInput.command || "";
  if (!cmd) done();
  if (classify(cmd) !== "write") done(); // read-only command — allow
  repoRoot = findRepoRootForBash(cmd);

  // git branch -d/-D: gated exclusively by /worktree-end's marker file.
  // Allowed when the marker matches the target branch and the recorded
  // worktree path resolves under WORKTREE_BASE_DIR; blocked unconditionally
  // otherwise (any worktree, including main and linked).
  if (isBranchDeleteCommand(cmd)) {
    if (isAllowedBranchDeleteViaMarker(cmd, repoRoot)) done();
    done({
      block: true,
      reason:
        "ENFORCE_WORKTREE: git branch -d/-D blocked. Reason: no matching /worktree-end marker.\n" +
        "Branch deletion is only authorised via /worktree-end, which writes\n" +
        "<git-common-dir>/info/pending-branch-delete with the target branch and the\n" +
        "worktree path being removed (must resolve under WORKTREE_BASE_DIR).\n" +
        "Direct git branch -d/-D from any worktree is prohibited.\n" +
        "Run: /worktree-end\n" +
        "Or set ENFORCE_WORKTREE=off in agents config to bypass.",
    });
  }

  // gh write commands (Group B) get an extra session-scope check before the
  // standard main/worktree enforcement below. The whitelist defines the set of
  // repos this session manages; gh writes outside the set are blocked even
  // from a worktree, on the principle that out-of-session repos are not the
  // current task's concern.
  if (isGhWriteCommand(cmd)) {
    const sessionRoots = getSessionRepoRoots();
    const detected = repoRoot ? normalizeForCompare(repoRoot) : null;

    if (!detected) {
      done({
        block: true,
        reason:
          "ENFORCE_WORKTREE: gh write blocked. Reason: cannot determine repo root for this command.\n" +
          "Run gh from inside a session repo's worktree, or set ENFORCE_WORKTREE=off.",
      });
    }
    if (!sessionRoots.has(detected)) {
      done({
        block: true,
        reason:
          `ENFORCE_WORKTREE: gh write blocked. Reason: target repo (${repoRoot}) is not in session scope.\n` +
          "Add this repo to ENFORCE_WORKTREE_EXTRA_REPOS in agents config, or run from a session repo.\n" +
          "Or set ENFORCE_WORKTREE=off to bypass.",
      });
    }
    // gh writes are GitHub operations, not local file writes — session-scope is sufficient.
    done();
  }

  // Bug 2 + Bug 1: non-gh Bash writes — check actual write targets.
  {
    const sessionRoots = getSessionRepoRoots();
    const excludePatterns = getExcludePatterns();
    const { targets, parseFailure } = collectBashWriteTargets(cmd);

    if (!parseFailure) {
      // Commands with sequencing operators (;, &&, ||) may contain un-extracted
      // in-scope writes (e.g. `echo x > /tmp/out; rm README.md`). Skip the
      // session-scope / EXCLUDE fast-paths for those; fall through to the
      // main-checkout block (fail-closed). Single | (pipe) is allowed — it is
      // needed for `cmd | tee /out` and carries no sequencing risk beyond the tee.
      if (!hasCommandSequencing(cmd)) {
        // Bug 2: all targets resolve outside session scope (incl. non-git paths) → allow.
        if (areAllBashTargetsOutsideSessionScope(targets, sessionRoots)) done();

        // Bug 1: all targets covered by EXCLUDE → allow.
        if (excludePatterns.length > 0 &&
            isWriteTargetAllExcluded(cmd, targets, repoRoot, excludePatterns)) {
          done();
        }
      }
    }

    // git -C <path> style (no file targets extracted): use repoRoot for scope check.
    if (!targets && !parseFailure && repoRoot) {
      if (!isInSessionScope(repoRoot, sessionRoots)) done();
    }
    // parseFailure → fail-closed: fall through to main-checkout block below.
  }
} else if (["Edit", "Write", "MultiEdit"].includes(toolName)) {
  const sessionRoots = getSessionRepoRoots();
  const excludePatterns = getExcludePatterns();

  if (toolName === "MultiEdit" && Array.isArray(toolInput.edits) && toolInput.edits.length > 0) {
    // Check every edit target — a mixed-repo MultiEdit must not slip through.
    for (const edit of toolInput.edits) {
      const fp = edit.file_path;
      if (!fp || typeof fp !== "string") continue;

      // Bug 1: EXCLUDE match → skip this edit (allow).
      if (isExcluded(fp, excludePatterns)) continue;

      const root = findRepoRoot(fp);
      // Bug 2: non-git path or outside session scope → skip (allow).
      if (!root || !isInSessionScope(root, sessionRoots)) continue;

      const isMC = isMainCheckout(root);
      const branch = getCurrentBranch(root);
      const protected_ = getProtectedBranches(root);
      if (isMC) {
        const branchDesc = branch ? `branch '${branch}'` : "detached HEAD";
        done({
          block: true,
          reason: `ENFORCE_WORKTREE: write blocked. Reason: main worktree (${branchDesc}).\nWork from a linked worktree (/worktree-start) or set ENFORCE_WORKTREE=off.`,
        });
      }
      if (branch && protected_.includes(branch)) {
        done({
          block: true,
          reason: `ENFORCE_WORKTREE: write blocked. Reason: protected branch '${branch}' in linked worktree.\nSwitch to a feature branch or set ENFORCE_WORKTREE=off.`,
        });
      }
    }
    done(); // all edits passed
  }
  const filePath = toolInput.file_path || toolInput.path;
  if (!filePath || typeof filePath !== "string") done();

  // Bug 1: EXCLUDE match → allow.
  if (isExcluded(filePath, excludePatterns)) done();

  repoRoot = findRepoRoot(filePath);

  // Bug 2: non-git path or outside session scope → allow.
  if (!repoRoot || !isInSessionScope(repoRoot, sessionRoots)) done();
} else {
  done(); // unrecognised tool — allow
}

if (!repoRoot) done(); // not in a git repo — allow

const mainCheckout = isMainCheckout(repoRoot);
const currentBranch = getCurrentBranch(repoRoot);
const protectedBranches = getProtectedBranches(repoRoot);

// Linked worktree on detached HEAD — allow (cannot determine branch)
if (!currentBranch && !mainCheckout) done();

if (mainCheckout) {
  // Allow isolated worktree lifecycle commands (Bash only).
  // These operate on .git/worktrees/ metadata or external paths, not tracked files,
  // and must be invoked from the main worktree.
  if (toolName === "Bash") {
    const cmd = toolInput.command || "";
    if (isAllowedWorktreeCommand(cmd, repoRoot)) done();
    if (isAllowedNewItemDirectory(cmd, repoRoot)) done();
    if (isAllowedFastForwardMerge(cmd)) done();
    if (isAllowedMarkerDelete(cmd, repoRoot)) done();
    if (isAllowedReadOnlyConfigCheck(cmd)) done();
    if (isAllowedPushAllExcluded(cmd, repoRoot, getExcludePatterns())) done();
  }

  // Allow Write/Edit to the pending-branch-delete marker. /worktree-end writes
  // this file from the main worktree before authorising git branch -d.
  if (["Write", "Edit"].includes(toolName)) {
    const fp = toolInput.file_path || toolInput.path;
    if (fp && isMarkerFilePath(fp, repoRoot)) done();
  }

  const branchDesc = currentBranch ? `branch '${currentBranch}'` : "detached HEAD";
  done({
    block: true,
    reason:
      `ENFORCE_WORKTREE: write blocked. Reason: main worktree (${branchDesc}).\n` +
      "Main worktree is reserved for merge/pull only. Work from a linked worktree.\n" +
      "Run: /worktree-start <task-name>\n" +
      "Or set ENFORCE_WORKTREE=off in agents config to allow direct main work.",
  });
}

if (currentBranch && protectedBranches.includes(currentBranch)) {
  done({
    block: true,
    reason:
      `ENFORCE_WORKTREE: write blocked. Reason: protected branch '${currentBranch}' in linked worktree.\n` +
      "Switch to a feature branch before writing.\n" +
      "Run: git switch -c feature/<task-name>\n" +
      "Or set ENFORCE_WORKTREE=off in agents config.",
  });
}

done(); // linked worktree on feature branch — allow

} // end if (require.main === module)

module.exports = {
  isAllowedFastForwardMerge,
  isBranchDeleteCommand,
  parseBranchDeleteTarget,
  isAllowedBranchDeleteViaMarker,
  isAllowedMarkerDelete,
  isAllowedReadOnlyConfigCheck,
  isMarkerFilePath,
  getWorktreeBaseDir,
  isAllowedPushAllExcluded,
};
