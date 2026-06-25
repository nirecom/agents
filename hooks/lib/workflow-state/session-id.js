"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");

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
    for (const raw of rawCandidates) {
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
