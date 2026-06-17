"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { normalizeCwd } = require("../lib/path-normalize");
const { parseCdCommand, parseCdCommandInInterpreter } = require("../lib/parse-git-args");

// Normalize a path to Windows form when possible. Handles Git Bash style
// `/c/path` → `C:\path` and `c:/path` → `c:\path` on win32.
function toWindowsPath(raw) {
  if (!raw) return raw;
  const driveMatch = raw.match(/^\/([a-zA-Z])(\/.*)?$/);
  if (driveMatch) {
    return driveMatch[1].toUpperCase() + ":\\" +
      (driveMatch[2] || "").replace(/\//g, "\\").replace(/^\\/, "");
  }
  if (process.platform === "win32" && /^[a-zA-Z]:\//.test(raw)) return raw.replace(/\//g, "\\");
  return raw;
}

// Trivalue (#885 Axis A):
//   true  → main worktree (--git-common-dir === --git-dir)
//   false → linked worktree (paths differ) OR spawnSync threw (fail-safe to
//           linked-worktree behavior — existing caller semantics)
//   null  → indeterminate: git rev-parse ran but returned non-zero
//           (non-git CWD, broken repo, etc.). Callers should treat null as
//           "checked but unresolved" — by convention block-side under
//           enforce-worktree (see #885 plan).
function isMainCheckout(repoCwd) {
  try {
    const common = spawnSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    const gitDir = spawnSync("git", ["rev-parse", "--git-dir"], {
      cwd: repoCwd, encoding: "utf8", timeout: 2000,
    });
    // Axis A (#885) trivalue:
    //   spawnSync error (e.g. ENOENT on cwd) → false (fail-safe, existing behavior)
    //   git rev-parse non-zero status → null (indeterminate: non-git CWD,
    //                                          broken repo, etc.)
    //   both succeed and paths match → true; mismatch → false
    if (common.error || gitDir.error) return false;
    if (common.status !== 0 || gitDir.status !== 0) return null;
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
  return toWindowsPath(raw);
}

function findRepoRootForBash(cmd) {
  const cArg = parseGitCPath(cmd);
  // Payload-derived `cd <absolute-path> && ...` extraction (issue #321).
  // No CLAUDE_PROJECT_DIR fallback — Approach E rejects it (start-time-fixed,
  // does not follow Bash `cd`).
  let cdArg = null;
  if (!cArg) {
    cdArg = parseCdCommandInInterpreter(cmd);
    if (!cdArg) cdArg = parseCdCommand(cmd);
  }
  let startDir = cArg || cdArg || process.cwd();
  if (typeof startDir === "string" && /^\/[a-zA-Z]\//.test(startDir)) {
    startDir = toWindowsPath(startDir);
  }
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

function findRepoRoot(filePath) {
  let dir;
  try {
    const normalized = normalizeCwd(filePath) || filePath;
    dir = path.dirname(path.resolve(normalized));
  } catch (e) {
    return null;
  }
  // Walk up to find an existing directory: a non-existent target path (e.g.
  // `rm "<repo>/path with spaces/file"` where the dir does not exist) must
  // still resolve to the enclosing repo. Without this walk, spawnSync's cwd
  // ENOENT yields null and the path is incorrectly treated as outside scope.
  try {
    let cur = dir;
    while (cur && !fs.existsSync(cur)) {
      const parent = path.dirname(cur);
      if (parent === cur) { cur = null; break; }
      cur = parent;
    }
    if (!cur) return null;
    dir = cur;
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

module.exports = {
  isMainCheckout,
  parseGitCPath,
  findRepoRootForBash,
  normalizeForCompare,
  resolveRepoRoot,
  findRepoRoot,
};
