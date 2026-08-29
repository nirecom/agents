"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");
const { isSameGitRepo } = require("../lib/git-common-dir");
// CPR-SSOT (#2108): the WORKTREE_NOTES parser and the own-worktree matcher were
// private copies here and in lib/resolve-workflow-session-id.js; both now share one.
const {
  readSessionIdFromWorktreeNotes,
  findOwnWorktreeDir,
  parseWorktreeDirs,
} = require("../lib/worktree-notes-session-ids");
// Direct submodule require (not the ./state-io barrel) to avoid a circular
// dependency: state-io's barrel pulls in modules that require session-id.js.
const { SESSION_ID_VALID_RE } = require("./state-io/core");

/**
 * The one enumeration of a transcript directory, reporting what could NOT be observed
 * instead of swallowing it. Returns { files, errors }: readable `.jsonl` REGULAR-FILE
 * entries as { name, mtime } (mtime descending), and [{ scope: "dir"|"file", path, code }]
 * — a failed readdir yields one `dir` error and no files, a failed lstatSync drops only
 * that file. lstat + regular-file-only, so a `.jsonl` symlink cannot pull a transcript in
 * from outside the directory (CPR-ORTH with the prune walker and bin/measure-norm-docs);
 * a skipped entry is not an error. _listJsonlByMtime below is the swallowing view.
 */
function listJsonlByMtimeStrict(transcriptDir) {
  const files = [];
  const errors = [];
  let names;
  try {
    names = fs.readdirSync(transcriptDir);
  } catch (e) {
    errors.push({ scope: "dir", path: transcriptDir, code: e.code || "EIO" });
    return { files, errors };
  }
  for (const name of names) {
    if (!name.endsWith(".jsonl")) continue;
    const full = path.join(transcriptDir, name);
    try {
      const st = fs.lstatSync(full);
      if (!st.isFile()) continue;
      files.push({ name, mtime: st.mtimeMs });
    } catch (e) {
      errors.push({ scope: "file", path: full, code: e.code || "EIO" });
    }
  }
  files.sort((a, b) => b.mtime - a.mtime);
  return { files, errors };
}

// Legacy view, preserved bit-for-bit: the original single try/catch returned [] whether
// the readdir or any individual statSync failed, so any observed error still yields [].
// Changing this to return partial results would change session resolution in state-io.js.
function _listJsonlByMtime(transcriptDir) {
  const r = listJsonlByMtimeStrict(transcriptDir);
  return r.errors.length > 0 ? [] : r.files;
}

function findMostRecentSessionIdInDir(transcriptDir) {
  const files = _listJsonlByMtime(transcriptDir);
  if (files.length === 0) return null;
  const base = path.basename(files[0].name, ".jsonl");
  return /^[A-Za-z0-9_-]+$/.test(base) ? base : null;
}

/**
 * Resolve the current session ID by priority:
 *   1. ctx.sessionIdFromInput   2. CLAUDE_CODE_SESSION_ID (CC-native; the only one
 *      reliably present in the Bash-tool subprocess — #1082, Anthropic bug #27987)
 *   3. CLAUDE_ENV_FILE   4. CLAUDE_SESSION_ID   5. ctx.transcriptPath basename
 *   6. WORKTREE_NOTES.md (CWD, git common-dir parent, then sibling worktrees)
 *   7. JSONL mtime scan — last resort
 */
function resolveSessionId(ctx = {}) {
  if (
    typeof ctx.sessionIdFromInput === "string" &&
    SESSION_ID_VALID_RE.test(ctx.sessionIdFromInput)
  ) {
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
      if (match && SESSION_ID_VALID_RE.test(match[1].trim())) return match[1].trim();
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
  const fromCwd = readSessionIdFromWorktreeNotes(path.join(process.cwd(), "WORKTREE_NOTES.md"));
  if (fromCwd) return fromCwd;
  try {
    const commonDir = execSync("git rev-parse --git-common-dir", {
      encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (commonDir) {
      const fromGit = readSessionIdFromWorktreeNotes(
        path.join(path.resolve(commonDir), "..", "WORKTREE_NOTES.md")
      );
      if (fromGit) return fromGit;
    }
  } catch (_) {
    // not in a git repo or git unavailable
  }
  // Priority 6c: sibling worktree scan — symmetric to resolve-workflow-session-id.js
  // Priority 1d (CPR-ORTH). Own-worktree-first: the worktree root that is CWD itself or
  // an ancestor of CWD wins immediately if its notes yield a Session-ID. Only NON-own
  // entries count as siblings; multiple distinct sibling Session-IDs are ambiguous →
  // null (fail-safe; do not fall through to the Priority 7 JSONL mtime scan).
  try {
    const wtOut = execSync("git worktree list --porcelain", {
      encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"],
    });
    const worktreeDirs = parseWorktreeDirs(wtOut);
    const ownDir = findOwnWorktreeDir(worktreeDirs, process.cwd());
    if (ownDir) {
      const ownSid = readSessionIdFromWorktreeNotes(path.join(ownDir, "WORKTREE_NOTES.md"));
      if (ownSid) return ownSid; // own worktree wins over any sibling
    }
    const hits = new Set();
    for (const dir of worktreeDirs) {
      if (dir === ownDir) continue; // exclude own from the sibling set
      const sid = readSessionIdFromWorktreeNotes(path.join(dir, "WORKTREE_NOTES.md"));
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
  listJsonlByMtimeStrict,
  findMostRecentSessionIdInDir,
  resolveSessionId,
};
