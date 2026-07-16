"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");
const { isSameGitRepo } = require("../git-common-dir");

function _listJsonlByMtime(transcriptDir) {
  try {
    return fs
      .readdirSync(transcriptDir)
      .filter((f) => f.endsWith(".jsonl"))
      .map((f) => ({
        name: f,
        mtime: fs.statSync(path.join(transcriptDir, f)).mtimeMs,
      }))
      .sort((a, b) => b.mtime - a.mtime);
  } catch (e) {
    return [];
  }
}

function findMostRecentSessionIdInDir(transcriptDir) {
  const files = _listJsonlByMtime(transcriptDir);
  if (files.length === 0) return null;
  const base = path.basename(files[0].name, ".jsonl");
  return /^[A-Za-z0-9_-]+$/.test(base) ? base : null;
}

function _readSessionIdFromWorktreeNotes(notesPath) {
  try {
    const content = fs.readFileSync(notesPath, "utf8");
    const m = content.match(/^Session-ID:\s*(\S+)\s*$/m);
    if (m && /^[A-Za-z0-9_-]+$/.test(m[1])) return m[1];
  } catch (_) {
    // ignore
  }
  return null;
}

/**
 * Identify the "own" worktree root among `dirs`: the entry whose path is `cwd`
 * itself or a proper ancestor of `cwd`. Uses path.resolve()-normalized prefix
 * matching with a path-separator boundary (so `C:/git/wt1` does not match
 * `C:/git/wt1-other`); on win32 the comparison is case-insensitive.
 * When multiple ancestors qualify (nested worktrees), the deepest wins.
 * Returns the ORIGINAL (unnormalized) dir string, or null when none matches.
 */
function _findOwnWorktreeDir(dirs, cwd) {
  const norm = (p) => (process.platform === "win32" ? p.toLowerCase() : p);
  const cwdNorm = norm(path.resolve(cwd));
  let own = null;
  let ownLen = -1;
  for (const dir of dirs) {
    if (!dir) continue;
    const dirNorm = norm(path.resolve(dir));
    const isMatch =
      cwdNorm === dirNorm ||
      (cwdNorm.startsWith(dirNorm) &&
        (dirNorm.endsWith("/") ||
          dirNorm.endsWith(path.sep) ||
          cwdNorm[dirNorm.length] === "/" ||
          cwdNorm[dirNorm.length] === path.sep));
    if (isMatch && dirNorm.length > ownLen) {
      own = dir;
      ownLen = dirNorm.length;
    }
  }
  return own;
}

/**
 * Resolve the current session ID with the following priority chain:
 *   1. ctx.sessionIdFromInput — non-empty string from hook input.session_id
 *   2. CLAUDE_CODE_SESSION_ID env var — CC-native, per-session-distinct,
 *      reliably present in the Bash-tool subprocess where CLAUDE_ENV_FILE is
 *      not propagated (#1082, Anthropic bug #27987)
 *   3. CLAUDE_ENV_FILE — KEY=VALUE file written by session-start.js
 *   4. CLAUDE_SESSION_ID env var — best-effort (Anthropic bug #27987)
 *   5. ctx.transcriptPath basename
 *   6. WORKTREE_NOTES.md (CWD, then git common-dir parent)
 *   7. JSONL mtime scan — last resort
 */
function resolveSessionId(ctx = {}) {
  if (typeof ctx.sessionIdFromInput === "string" && ctx.sessionIdFromInput.length > 0) {
    return ctx.sessionIdFromInput;
  }
  // CC-native session id, set directly in tool and hook subprocesses. Reliably
  // present where the manufactured CLAUDE_SESSION_ID relay (read below) is not —
  // the Bash-tool path, where CLAUDE_ENV_FILE is not propagated. Without this,
  // resolution falls through to the JSONL mtime scan, which returns the most
  // recently active OTHER session in a concurrent environment (#1082).
  const codeSid = process.env.CLAUDE_CODE_SESSION_ID;
  if (codeSid && /^[A-Za-z0-9_-]+$/.test(codeSid.trim())) return codeSid.trim();
  const envFile = process.env.CLAUDE_ENV_FILE;
  if (envFile) {
    try {
      const content = fs.readFileSync(envFile, "utf8");
      const match = content.match(/^CLAUDE_SESSION_ID=(.+)$/m);
      if (match) return match[1].trim();
    } catch (e) {
      // fall through
    }
  }
  const envSid = process.env.CLAUDE_SESSION_ID;
  if (envSid && /^[A-Za-z0-9_-]+$/.test(envSid.trim())) return envSid.trim();
  if (typeof ctx.transcriptPath === "string" && ctx.transcriptPath.length > 0) {
    const base = path.basename(ctx.transcriptPath, ".jsonl");
    if (/^[A-Za-z0-9_-]+$/.test(base)) return base;
  }
  const fromCwd = _readSessionIdFromWorktreeNotes(path.join(process.cwd(), "WORKTREE_NOTES.md"));
  if (fromCwd) return fromCwd;
  try {
    const commonDir = execSync("git rev-parse --git-common-dir", {
      encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (commonDir) {
      const fromGit = _readSessionIdFromWorktreeNotes(
        path.join(path.resolve(commonDir), "..", "WORKTREE_NOTES.md")
      );
      if (fromGit) return fromGit;
    }
  } catch (_) {
    // not in a git repo or git unavailable
  }
  // Priority 6c: sibling worktree scan — symmetric to resolve-workflow-session-id.js
  // Priority 1d (CPR-5). Reached only after Priority 6/6b (CWD notes reads) fail.
  // Own-worktree-first: identify the worktree root that is CWD itself or an ancestor
  // of CWD (so a CWD in a linked-worktree SUBDIR still resolves to that worktree, not
  // a sibling). If own's WORKTREE_NOTES.md yields a Session-ID, it wins immediately.
  // Only NON-own entries are collected as siblings; multiple distinct sibling
  // Session-IDs are ambiguous → null (fail-safe; do not fall through to Priority 7
  // JSONL mtime scan).
  try {
    const wtOut = execSync("git worktree list --porcelain", {
      encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"],
    });
    const worktreeDirs = [];
    let current = null;
    for (const line of wtOut.split("\n")) {
      if (line.startsWith("worktree ")) {
        current = line.slice("worktree ".length).trim();
      } else if (line === "" && current !== null) {
        if (current) worktreeDirs.push(current);
        current = null;
      }
    }
    // Handle last entry if no trailing blank line (R6).
    if (current) worktreeDirs.push(current);

    const ownDir = _findOwnWorktreeDir(worktreeDirs, process.cwd());
    if (ownDir) {
      const ownSid = _readSessionIdFromWorktreeNotes(path.join(ownDir, "WORKTREE_NOTES.md"));
      if (ownSid) return ownSid; // own worktree wins over any sibling
    }
    const hits = new Set();
    for (const dir of worktreeDirs) {
      if (dir === ownDir) continue; // exclude own from the sibling set
      const sid = _readSessionIdFromWorktreeNotes(path.join(dir, "WORKTREE_NOTES.md"));
      if (sid) hits.add(sid);
    }
    if (hits.size === 1) return [...hits][0];
    if (hits.size > 1) return null; // ambiguous: distinct Session-IDs → fail-safe
  } catch (_) {}
  try {
    const transcriptBase =
      process.env.CLAUDE_TRANSCRIPT_BASE_DIR ||
      path.join(os.homedir(), ".claude", "projects");
    const rawCandidates = [
      process.env.CLAUDE_PROJECT_DIR,
      process.cwd(),
    ].filter(Boolean);
    try {
      const rp = fs.realpathSync(process.cwd());
      if (rp !== process.cwd()) rawCandidates.push(rp);
    } catch (e) {
      // realpath unavailable
    }
    const agentsRootForP7 =
      process.env.AGENTS_CONFIG_DIR || path.resolve(__dirname, "..", "..", "..");
    for (const raw of rawCandidates) {
      if (!isSameGitRepo(path.resolve(raw), agentsRootForP7)) continue;
      const encoded = path
        .resolve(raw)
        .toLowerCase()
        .replace(/[^a-zA-Z0-9]/g, "-");
      const sid = findMostRecentSessionIdInDir(
        path.join(transcriptBase, encoded),
      );
      if (sid) return sid;
    }
  } catch (e) {
    // fall through
  }
  return null;
}

module.exports = {
  _listJsonlByMtime,
  findMostRecentSessionIdInDir,
  resolveSessionId,
};
