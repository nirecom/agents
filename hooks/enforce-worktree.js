#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce worktree-based parallel session workflow.
//
// Scope:
//   Blocks Edit/Write/MultiEdit/Bash write operations when:
//     1. Running in the main git checkout (not a linked worktree), regardless of branch.
//     2. Running on a protected branch even inside a linked worktree.
//   Allows writes only from a linked worktree on a non-protected branch.
//
// Main checkout detection:
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
const { spawnSync } = require("child_process");
const path = require("path");

try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { normalizeCwd } = require("./lib/path-normalize");
const { WRITE_PATTERNS, classify } = require("./lib/bash-write-patterns");

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

/** Strip double- and single-quoted string content so shell operators inside
 *  quotes are ignored when scanning for chaining metacharacters.
 *  Does NOT handle PowerShell backtick escapes or here-strings. */
function stripQuotedSegments(str) {
  return str
    .replace(/"(?:[^"\\]|\\.)*"/g, '""')
    .replace(/'[^']*'/g, "''");
}

/** True if cmd contains shell chaining/pipe operators outside of quotes.
 *  Note: bare `&` also matches PowerShell's call operator (& git.exe ...),
 *  so `& git.exe worktree add` is conservatively rejected. */
function hasShellChaining(cmd) {
  return /[|;&]/.test(stripQuotedSegments(cmd));
}

/**
 * True when targetPath resolves to a location OUTSIDE repoRoot.
 * Relative paths are resolved against process.cwd() (the main checkout when
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

  // remove/prune do not create new checkout paths — always allow from main checkout
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

// Returns true when repoCwd is the main (non-linked) checkout.
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
//   - Each path listed in ENFORCE_WORKTREE_EXTRA_REPOS (comma-separated)
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
    .split(",").map((s) => s.trim()).filter(Boolean);
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
} else if (["Edit", "Write", "MultiEdit"].includes(toolName)) {
  if (toolName === "MultiEdit" && Array.isArray(toolInput.edits) && toolInput.edits.length > 0) {
    // Check every edit target — a mixed-repo MultiEdit must not slip through.
    for (const edit of toolInput.edits) {
      const fp = edit.file_path;
      if (!fp || typeof fp !== "string") continue;
      const root = findRepoRoot(fp);
      if (!root) continue;
      const isMC = isMainCheckout(root);
      const branch = getCurrentBranch(root);
      const protected_ = getProtectedBranches(root);
      if (isMC) {
        const branchDesc = branch ? `branch '${branch}'` : "detached HEAD";
        done({
          block: true,
          reason: `ENFORCE_WORKTREE: write blocked. Reason: main checkout (${branchDesc}).\nWork from a linked worktree (/worktree-start) or set ENFORCE_WORKTREE=off.`,
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
  repoRoot = findRepoRoot(filePath);
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
  // and must be invoked from the main checkout.
  if (toolName === "Bash") {
    const cmd = toolInput.command || "";
    if (isAllowedWorktreeCommand(cmd, repoRoot)) done();
    if (isAllowedNewItemDirectory(cmd, repoRoot)) done();
  }

  const branchDesc = currentBranch ? `branch '${currentBranch}'` : "detached HEAD";
  done({
    block: true,
    reason:
      `ENFORCE_WORKTREE: write blocked. Reason: main checkout (${branchDesc}).\n` +
      "Main checkout is reserved for merge/pull only. Work from a linked worktree.\n" +
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
