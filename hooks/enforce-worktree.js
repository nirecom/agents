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
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const path = require("path");

try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { normalizeCwd } = require("./lib/path-normalize");
const { resolveSessionId, getWorkflowDir } = require("./lib/workflow-state");
const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
const { stripQuotedArgs } = require("./lib/strip-quoted-args");
const { WRITE_PATTERNS, classify } = require("./lib/bash-write-patterns");
const { parseExcludePatterns, matchesAnyExcludePattern } = require("./lib/glob-match");
const { parseCdCommand } = require("./lib/parse-git-args");

// Cache for payload-derived absolute paths for the CURRENT hook invocation.
// Populated once at the dispatch site by setPayloadDerivedPaths(); read by
// getSessionRepoRoots(). Implicitly reset per process (one invocation = one
// process). Issue #321 — payload-derived repo resolution.
let _payloadDerivedPaths = [];
function setPayloadDerivedPaths(paths) {
  _payloadDerivedPaths = (paths || []).filter(Boolean);
}
function _getPayloadDerivedPaths() { return _payloadDerivedPaths.slice(); }
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

/**
 * Returns the index of the first unquoted `&&` in cmd, or -1 if none.
 * Tracks single- and double-quote state so `&&` inside quoted paths is ignored.
 *
 * Note: does not track backslash escapes. This matches the same simplification
 * used by hasShellChaining / stripQuotedArgs — acceptable for a UX guard.
 */
function findFirstUnquotedAnd(cmd) {
  let inSingle = false, inDouble = false;
  for (let i = 0; i < cmd.length - 1; i++) {
    const c = cmd[i];
    if (c === "'" && !inDouble) { inSingle = !inSingle; continue; }
    if (c === '"' && !inSingle) { inDouble = !inDouble; continue; }
    if (!inSingle && !inDouble && c === "&" && cmd[i + 1] === "&") return i;
  }
  return -1;
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
 * True when cmd is exactly:
 *   cd "<main-worktree>" && git [-C "<main-worktree>"] worktree (remove|prune) [...]
 *
 * Rationale (#294): VS Code resets the Bash tool's CWD on each call on Windows,
 * so the documented two-separate-call sequence (step 6b.5: `cd <main>` then
 * step 6c: `git -C <main> worktree remove <linked>`) breaks. This combined form
 * runs both in a single Bash call, which is CWD-reset-immune.
 *
 * Safety constraints (all must hold):
 *   - Exactly one unquoted && (no further chaining via ||, ;, |, $(, backtick)
 *   - LHS is `cd <path>` where <path> resolves to repoRoot (the main worktree)
 *   - RHS is `git [-C <path>] worktree remove|prune [args]` — no worktree add,
 *     no --force / -f
 *   - If RHS contains -C <path>, that path must also resolve to repoRoot
 *
 * Does NOT call hasShellChaining() — && is the specifically allowed operator.
 * Safety is enforced by structural clause matching above.
 */
function isAllowedCdWorktreeRemove(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  if (!repoRoot) return false;

  // Find the one allowed && using a quote-aware scanner.
  const andIdx = findFirstUnquotedAnd(cmd);
  if (andIdx < 0) return false;
  const lhs = cmd.slice(0, andIdx).trim();
  const rhs = cmd.slice(andIdx + 2).trim();
  if (!lhs || !rhs) return false;

  // No second && and no other chaining on either side.
  if (findFirstUnquotedAnd(rhs) >= 0) return false;
  const lhsStripped = stripQuotedArgs(lhs);
  const rhsStripped = stripQuotedArgs(rhs);
  if (/[|;]|\$\(|`/.test(lhsStripped)) return false;
  if (/[|;]|\$\(|`/.test(rhsStripped)) return false;

  // LHS: `cd <path>` where <path> resolves to repoRoot (the main worktree).
  const cdMatch = lhs.match(/^cd\s+(?:"([^"]+)"|'([^']+)'|(\S+))\s*$/);
  if (!cdMatch) return false;
  const cdPath = cdMatch[1] || cdMatch[2] || cdMatch[3];
  if (!cdPath) return false;
  try {
    const normCd   = normalizeCwd(cdPath)   || cdPath;
    const normBase = normalizeCwd(repoRoot) || repoRoot;
    if (path.resolve(normCd).toLowerCase() !== path.resolve(normBase).toLowerCase()) return false;
  } catch (e) { return false; }

  // RHS: git [-C <main>] worktree (remove|prune) [...] — no add, no --force/-f.
  if (!/^git\b/.test(rhs)) return false;
  if (!/\bworktree\s+(?:remove|prune)\b/.test(rhs)) return false;
  if (/\s--force\b/.test(rhs)) return false;
  if (/(?:^|\s)-f(?:\s|$)/.test(rhs)) return false;

  // If RHS has -C <path>, it must resolve to repoRoot.
  // Reject multiple -C flags — parseGitCPath only validates the first;
  // git uses the last (or cumulative), creating an ambiguity gap.
  if ((rhs.match(/\s-C\s/g) || []).length > 1) return false;
  if (/\s-C\s/.test(rhs)) {
    const cArg = parseGitCPath(rhs);
    if (!cArg) return false;
    try {
      const normC    = normalizeCwd(cArg)    || cArg;
      const normBase = normalizeCwd(repoRoot) || repoRoot;
      if (path.resolve(normC).toLowerCase() !== path.resolve(normBase).toLowerCase()) return false;
    } catch (e) { return false; }
  }

  return true;
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

// Resolve <workflow-plans-dir>/worktree-end/ — stores /worktree-end branch-delete
// markers outside .git/ (Claude Code protected path that always prompts on write).
// Precedent: PR #256 moved .claude/plans/ → ~/.workflow-plans/ for the same reason.
function getWorktreeEndDir() {
  return path.join(getWorkflowPlansDir(), "worktree-end");
}

// Stable per-repo id for marker filenames. Computed from the absolute path of
// the repo's git-common-dir (shared across all linked worktrees of the same repo)
// so every worktree of repo R produces the same id.
// Returns null if git-common-dir cannot be resolved (caller must fail-closed).
function getRepoId(repoRoot) {
  if (!repoRoot) return null;
  try {
    const r = spawnSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return null;
    const common = path.resolve(repoRoot, (r.stdout || "").trim());
    return crypto.createHash("sha256").update(common).digest("hex").slice(0, 16);
  } catch (e) { return null; }
}

// Compute the marker file path for a given (repoRoot, branch) pair.
// Filename: pending-branch-delete-<repo-id>--<encodeURIComponent(branch)>
// encodeURIComponent makes any git-legal branch name filesystem-safe
// (e.g. feature/foo → feature%2Ffoo, zero collision risk).
// Returns null when repo-id resolution fails — caller MUST fail-closed.
function getMarkerPath(repoRoot, branch) {
  if (!branch || typeof branch !== "string") return null;
  try {
    const id = getRepoId(repoRoot);
    if (!id) return null;
    const fname = "pending-branch-delete-" + id + "--" + encodeURIComponent(branch);
    return path.join(getWorktreeEndDir(), fname);
  } catch (e) { return null; }
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
 *   path:    <workflow-plans>/worktree-end/pending-branch-delete-<repo-id>--<encoded-branch>
 *   format:  line 1 = target branch name
 *            line 2 = absolute path of the worktree being removed
 *
 * Both must match: branch name == target, worktree path resolves under
 * WORKTREE_BASE_DIR. This narrows the exemption to /worktree-end-driven
 * cleanups; ad-hoc `git branch -D` from any worktree is still blocked.
 */
function isAllowedBranchDeleteViaMarker(cmd, repoRoot) {
  if (hasShellChaining(cmd)) return false;
  const target = parseBranchDeleteTarget(cmd);
  if (!target) return false;
  if (!repoRoot) return false;

  const markerPath = getMarkerPath(repoRoot, target);
  if (!markerPath) return false;

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

  // Extract exactly one positional target.
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
  if (!nTarget) return false;

  // Validate: target must be under <workflow-plans>/worktree-end/.
  let wtDir;
  try { wtDir = norm(getWorktreeEndDir()); } catch (e) { return false; }
  if (!wtDir) return false;
  const inDir = nTarget === wtDir ||
                nTarget.startsWith(wtDir + path.sep) ||
                nTarget.startsWith(wtDir + "/");
  if (!inDir) return false;

  // Validate: filename must start with pending-branch-delete-<this-repo-id>--.
  const id = getRepoId(repoRoot);
  if (!id) return false;
  const targetBase = path.basename(target);
  const targetBaseNorm = process.platform === "win32" ? targetBase.toLowerCase() : targetBase;
  const expectedPrefix = process.platform === "win32"
    ? ("pending-branch-delete-" + id + "--").toLowerCase()
    : ("pending-branch-delete-" + id + "--");
  if (!targetBaseNorm.startsWith(expectedPrefix)) return false;

  // Read marker. ENOENT → no-op delete is allowed (stale marker cleanup).
  // Any other read error → fail-closed.
  // Use nTarget (normalized) to match the path that passed validation.
  let content;
  try { content = fs.readFileSync(nTarget, "utf8"); }
  catch (e) { return e.code === "ENOENT"; }
  const lines = content.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length < 1) return false;
  const markerBranch = lines[0];

  // Branch must no longer exist: status 1 = not found (allow).
  // status 0 = exists (block); status >=2 or null = fatal (fail-closed).
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
 * True if filePath is a valid pending-branch-delete marker location for repoRoot.
 * Validates: path is under <workflow-plans>/worktree-end/, filename starts with
 * pending-branch-delete-<this-repo-id>--, and has a non-empty branch suffix.
 * Allows Write/Edit tool calls to the marker from the main worktree:
 * /worktree-end writes this file before calling git branch -d.
 */
function isMarkerFilePath(filePath, repoRoot) {
  if (!filePath || !repoRoot) return false;

  const id = getRepoId(repoRoot);
  if (!id) return false;

  const norm = (p) => {
    try {
      const n = normalizeCwd(p) || p;
      const r = path.resolve(n);
      return process.platform === "win32" ? r.toLowerCase() : r;
    } catch (e) { return null; }
  };
  const nTarget = norm(filePath);
  let wtDir;
  try { wtDir = norm(getWorktreeEndDir()); } catch (e) { return false; }
  if (!nTarget || !wtDir) return false;

  const inDir = nTarget === wtDir ||
                nTarget.startsWith(wtDir + path.sep) ||
                nTarget.startsWith(wtDir + "/");
  if (!inDir) return false;

  const targetBase = path.basename(filePath);
  const targetBaseNorm = process.platform === "win32" ? targetBase.toLowerCase() : targetBase;
  const expectedPrefix = process.platform === "win32"
    ? ("pending-branch-delete-" + id + "--").toLowerCase()
    : ("pending-branch-delete-" + id + "--");
  if (!targetBaseNorm.startsWith(expectedPrefix)) return false;

  // Branch portion (after `--`) must be non-empty.
  return targetBase.length > expectedPrefix.length;
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
  if (hasShellChaining(cmd)) return false;
  if (!/\bgit\b/.test(cmd)) return false;

  // -C path, if present, must resolve to repoRoot.
  // Reject multiple -C flags — parseGitCPath only validates the first;
  // git uses the last (or cumulative), creating an ambiguity gap.
  if ((cmd.match(/\s-C\s/g) || []).length > 1) return false;
  if (/\s-C\s/.test(cmd)) {
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
    return wtCount === 1; // main worktree only = cleanup complete
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
  // Payload-derived `cd <absolute-path> && ...` extraction (issue #321).
  // No CLAUDE_PROJECT_DIR fallback — Approach E rejects it (start-time-fixed,
  // does not follow Bash `cd`).
  const cdArg = cArg ? null : parseCdCommand(cmd);
  const startDir = cArg || cdArg || process.cwd();
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
  // Include payload-derived paths from the CURRENT hook invocation (issue #321).
  // Scope is limited to THIS command's explicitly named paths — we do NOT
  // enumerate all linked worktrees of cwdRoot (that would broaden the gh-write
  // guard beyond user intent).
  for (const p of _payloadDerivedPaths) {
    const r = resolveRepoRoot(p);
    if (r) roots.add(r);
  }
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

function isPositionInsideQuotes(cmd, pos) {
  let inSingle = false, inDouble = false;
  for (let i = 0; i < pos; i++) {
    const c = cmd[i];
    if (c === "\\" && i + 1 < cmd.length) { i++; continue; }
    if (c === "'" && !inDouble) inSingle = !inSingle;
    else if (c === '"' && !inSingle) inDouble = !inDouble;
  }
  return inSingle || inDouble;
}

function findEndOfEnvVarValue(cmd, startPos) {
  let inSingle = false, inDouble = false;
  for (let i = startPos; i < cmd.length; i++) {
    const c = cmd[i];
    if (c === "\\" && i + 1 < cmd.length) { i++; continue; }
    if (c === "'" && !inDouble) { inSingle = !inSingle; continue; }
    if (c === '"' && !inSingle) { inDouble = !inDouble; continue; }
    if (!inSingle && !inDouble && /\s/.test(c)) return i;
  }
  return cmd.length;
}

function envVarPrefixesGit(cmd, startPos) {
  const findNextTopLevel = (re) => {
    const r = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
    r.lastIndex = startPos;
    let m;
    while ((m = r.exec(cmd)) !== null) {
      if (!isPositionInsideQuotes(cmd, m.index)) return m;
    }
    return null;
  };
  const gitMatch = findNextTopLevel(/\bgit\b/);
  const sepMatch = findNextTopLevel(/[;|&]/);
  if (!gitMatch) return false;
  if (!sepMatch) return true;
  return gitMatch.index < sepMatch.index;
}

/**
 * True if cmd attempts to bypass git hooks via:
 *   - git -c core.hooksPath=<value>              (Pass A2, unquoted)
 *   - git -c "core.hooksPath=<value>"            (Pass B, double-quoted value)
 *   - git -c 'core.hooksPath=<value>'            (Pass B, single-quoted value)
 *   - git --config-env=core.hooksPath=VAR        (Pass A1, env-var indirection)
 *   - git --config-env core.hooksPath=VAR        (Pass A1, separated)
 *   - GIT_CONFIG_PARAMETERS=<value-containing-core.hooksPath> git ...
 *                                                 (Pass C1, env-var prefix)
 *   - GIT_CONFIG_KEY_<n>=core.hooksPath ... git ... (Pass C2, batch env-var)
 *
 * Out of scope: bash/sh/pwsh wrapper bypass, shell variable/alias/command-substitution
 * bypass, persistent git config writes. See plan for rationale.
 */
function hasGitHooksBypass(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  if (!/\bgit\b/.test(cmd)) return false;
  if (
    !/core\.hooksPath/i.test(cmd) &&
    !/--config-env\b/i.test(cmd) &&
    !/\bGIT_CONFIG_(?:PARAMETERS|COUNT|KEY_\d+|VALUE_\d+)\s*=/i.test(cmd)
  ) {
    return false;
  }

  const G =
    "(?:\\s+(?:--[A-Za-z][\\w-]*(?:=\\S+)?|-[A-Za-z]\\S*)(?:\\s+[^-\\s]\\S*)?)*";

  const stripped = stripQuotedArgs(cmd);

  // Pass A1: --config-env=core.hooksPath= or --config-env core.hooksPath=
  if (new RegExp("\\bgit\\b" + G + "\\s+--config-env(?:=|\\s+)core\\.hooksPath\\s*=", "i").test(stripped))
    return true;

  // Pass A2: -c core.hooksPath= (unquoted)
  if (new RegExp("\\bgit\\b" + G + "\\s+-c\\s+core\\.hooksPath\\s*=", "i").test(stripped))
    return true;

  // Pass B: -c "core.hooksPath=…" / -c 'core.hooksPath=…' (raw cmd, loop all matches)
  const reB = new RegExp("\\bgit\\b" + G + "\\s+-c\\s+[\"']core\\.hooksPath\\s*=", "ig");
  for (let mB; (mB = reB.exec(cmd)) !== null; ) {
    if (!isPositionInsideQuotes(cmd, mB.index)) return true;
  }

  // Pass C1: GIT_CONFIG_PARAMETERS=<value> where value contains core.hooksPath,
  // value is parsed via findEndOfEnvVarValue (NOT cmd-wide), and the env-var
  // actually prefixes a git invocation. Loop over all matches.
  const reC1 = /(?:^|[\s;|&])GIT_CONFIG_PARAMETERS\s*=/ig;
  for (let mC1; (mC1 = reC1.exec(cmd)) !== null; ) {
    if (isPositionInsideQuotes(cmd, mC1.index)) continue;
    const valStart = mC1.index + mC1[0].length;
    const valEnd = findEndOfEnvVarValue(cmd, valStart);
    const value = cmd.slice(valStart, valEnd);
    if (/core\.hooksPath/i.test(value) && envVarPrefixesGit(cmd, valEnd)) {
      return true;
    }
  }

  // Pass C2: GIT_CONFIG_KEY_<n>=core.hooksPath ... git ... (batch env-var config),
  // gated by envVarPrefixesGit. Loop over all matches.
  const reC2 = /(?:^|[\s;|&])GIT_CONFIG_KEY_\d+\s*=['"]?core\.hooksPath\b/ig;
  for (let mC2; (mC2 = reC2.exec(cmd)) !== null; ) {
    if (isPositionInsideQuotes(cmd, mC2.index)) continue;
    if (envVarPrefixesGit(cmd, mC2.index + mC2[0].length)) return true;
  }

  return false;
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

// Session-scoped escape hatch: if the current session has a marker file,
// treat as ENFORCE_WORKTREE=off for this session only. Set via:
//   echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF[: reason]>>"
// Restore by deleting the marker. Fail-closed when sessionId is unresolvable.
try {
  const sid = (input && input.session_id) || resolveSessionId();
  if (sid && /^[A-Za-z0-9_-]+$/.test(sid)) {
    const markerPath = path.join(getWorkflowDir(), `${sid}.worktree-off`);
    if (fs.existsSync(markerPath)) {
      process.stderr.write(
        `enforce-worktree: session override active (marker: ${markerPath}). ` +
          `Delete the marker to restore enforcement.\n`
      );
      done();
    }
  }
} catch (e) {
  process.stderr.write(
    `enforce-worktree: marker check failed (${e.message}); enforcement remains ON.\n`
  );
}

// Defence-in-depth: if process.cwd() is unresolvable (e.g. after
// git worktree remove from inside the removed worktree), fail-open.
// Root cause fix: skills/worktree-end/SKILL.md step 6b.5 (cd <main> before remove).
// See issue #268. Fail-open ONLY for ENOENT / missing-dir — not all errors.
let _cwd;
try {
  _cwd = process.cwd();
} catch (e) {
  if (e && e.code === "ENOENT") {
    process.stderr.write(
      "enforce-worktree: fail-open — process.cwd() threw ENOENT (issue #268 backstop).\n"
    );
    done();
  }
  throw e; // unexpected error: do not silently fail-open
}
if (!fs.existsSync(_cwd)) {
  process.stderr.write(
    "enforce-worktree: fail-open — process.cwd() points to a deleted directory (issue #268 backstop).\n"
  );
  done();
}

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

// Populate payload-derived-path cache for this invocation (issue #321).
// Read by getSessionRepoRoots() to scope the gh-write guard to the paths
// the CURRENT command names explicitly.
{
  const derived = [];
  if (toolName === "Bash") {
    const _cmd = toolInput.command || "";
    const _cArg = parseGitCPath(_cmd);
    if (_cArg && path.isAbsolute(_cArg)) derived.push(_cArg);
    const _cdArg = parseCdCommand(_cmd);
    if (_cdArg) derived.push(_cdArg);
  } else if (toolName === "Edit" || toolName === "Write" || toolName === "MultiEdit") {
    const fp = toolInput.file_path || toolInput.path;
    if (fp && typeof fp === "string" && path.isAbsolute(fp)) derived.push(fp);
    if (toolName === "MultiEdit" && Array.isArray(toolInput.edits)) {
      for (const e of toolInput.edits) {
        if (e && typeof e.file_path === "string" && path.isAbsolute(e.file_path)) {
          derived.push(e.file_path);
        }
      }
    }
  }
  setPayloadDerivedPaths(derived);
}

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
        "<workflow-plans>/worktree-end/pending-branch-delete-<repo-id>--<encoded-branch>\n" +
        "with the target branch and the worktree path being removed (must resolve under WORKTREE_BASE_DIR).\n" +
        "Direct git branch -d/-D from any worktree is prohibited.\n" +
        "Run: /worktree-end\n" +
        "Or set ENFORCE_WORKTREE=off in agents config to bypass.",
    });
  }

  if (hasGitHooksBypass(cmd)) {
    done({
      block: true,
      reason:
        "ENFORCE_WORKTREE: git hooks bypass blocked. Reason: hook-disabling override.\n" +
        "Blocked: git -c core.hooksPath=…, git --config-env=core.hooksPath=…,\n" +
        "GIT_CONFIG_PARAMETERS=…core.hooksPath… git …, and\n" +
        "GIT_CONFIG_KEY_<n>=core.hooksPath … git ….\n" +
        "These disable pre-commit / commit-msg / pre-push hooks.\n" +
        "Remove the override, or set ENFORCE_WORKTREE=off in agents config\n" +
        "if the bypass is intentional.",
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
    if (isAllowedCdWorktreeRemove(cmd, repoRoot)) done();
    if (isAllowedNewItemDirectory(cmd, repoRoot)) done();
    if (isAllowedFastForwardMerge(cmd)) done();
    if (isAllowedMarkerDelete(cmd, repoRoot)) done();
    if (isAllowedReadOnlyConfigCheck(cmd)) done();
    if (isAllowedPushAllExcluded(cmd, repoRoot, getExcludePatterns())) done();
    if (isAllowedMainWorktreeCleanup(cmd, repoRoot)) done();
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
  hasGitHooksBypass,
  findFirstUnquotedAnd,
  isAllowedMainWorktreeCleanup,
  isAllowedCdWorktreeRemove,
  findRepoRootForBash,
  getSessionRepoRoots,
  parseGitCPath,
  setPayloadDerivedPaths,
  _getPayloadDerivedPaths,
};
