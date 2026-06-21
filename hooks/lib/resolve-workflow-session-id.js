"use strict";

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const PRIORITY3_DAYS_BACK = 2;
const CONTEXT_READ_CAP_BYTES = 16384;

function _readSessionIdFromWorktreeNotes(notesPath) {
  try {
    const content = fs.readFileSync(notesPath, "utf8");
    const m = content.match(/^Session-ID:\s*(\S+)\s*$/m);
    if (m && /^[A-Za-z0-9_-]+$/.test(m[1])) return m[1];
  } catch (_) {}
  return null;
}

/**
 * Resolve the workflow session ID (wsid) — the timestamped session prefix used by
 * plan artifacts in WORKFLOW_PLANS_DIR (e.g. `<YYYYMMDD-HHMMSS>-intent.md`).
 * Distinct from resolveSessionId() which returns the CC session UUID.
 *
 * Priority chain:
 *   1. WORKTREE_NOTES.md Session-ID: line in CWD or git common-dir parent
 *      (written by /worktree-start — gold source).
 *   2. CLAUDE_ENV_FILE -> CLAUDE_SESSION_ID value (charset-validated),
 *      if `<value>-intent.md` exists in plans-dir.
 *   3. Depth-score scan of `*-context.md` filenames in plans-dir, filtered by charset and
 *      same-day date-sanity (prefix must start with today's local YYYYMMDD).
 *      Each candidate scores depth: 2 = detail.md present, 1 = intent.md only, 0 = stub.
 *      Sort order: depth desc, mtime desc, sid asc (depth tie-breaks before mtime).
 * Returns null on any failure (no throw).
 */
function resolveWorkflowSessionId(_ctx = {}) {
  const { getWorkflowPlansDir } = require("./workflow-plans-dir");
  let plansDir;
  try {
    plansDir = getWorkflowPlansDir();
  } catch (_) {
    return null;
  }

  // Priority 1: WORKTREE_NOTES.md Session-ID (written by /worktree-start — gold source).
  const fromCwd = _readSessionIdFromWorktreeNotes(
    path.join(process.cwd(), "WORKTREE_NOTES.md")
  );
  if (fromCwd) return fromCwd;
  try {
    const commonDir = execSync("git rev-parse --git-common-dir", {
      encoding: "utf8",
      timeout: 2000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (commonDir) {
      const fromGit = _readSessionIdFromWorktreeNotes(
        path.join(path.resolve(commonDir), "..", "WORKTREE_NOTES.md")
      );
      if (fromGit) return fromGit;
    }
  } catch (_) {}

  // Priority 2: CLAUDE_ENV_FILE → CLAUDE_SESSION_ID + intent.md existence check.
  // Already guards against stub selection: falls through to Priority 3 only when intent.md is absent.
  const envFile = process.env.CLAUDE_ENV_FILE;
  if (envFile) {
    try {
      const content = fs.readFileSync(envFile, "utf8");
      const match = content.match(/^CLAUDE_SESSION_ID=(.+)$/m);
      if (match) {
        const value = match[1].trim();
        if (
          /^[A-Za-z0-9_-]+$/.test(value) &&
          fs.existsSync(path.join(plansDir, value + "-intent.md"))
        ) {
          return value;
        }
      }
    } catch (_) {
      // fall through
    }
  }

  let entries;
  try {
    entries = fs.readdirSync(plansDir);
  } catch (_) {
    return null;
  }

  const now = new Date();
  const allowedDateStrs = [];
  for (let i = 0; i < PRIORITY3_DAYS_BACK; i++) {
    const d = new Date(now);
    d.setDate(d.getDate() - i);
    allowedDateStrs.push(
      String(d.getFullYear()) +
        String(d.getMonth() + 1).padStart(2, "0") +
        String(d.getDate()).padStart(2, "0")
    );
  }

  // Read CC UUID from CLAUDE_ENV_FILE (re-read for Priority 3 bucket-sort tie-break).
  let ccUuid = "";
  if (envFile) {
    try {
      const content = fs.readFileSync(envFile, "utf8");
      // Use the LAST match — session-start.js appends on every new session,
      // so earlier entries are stale CC UUIDs from previous sessions.
      const all = content.match(/^CLAUDE_SESSION_ID=(.+)$/gm) || [];
      if (all.length > 0) {
        const value = all[all.length - 1].replace(/^CLAUDE_SESSION_ID=/, "").trim();
        if (/^[A-Za-z0-9_-]+$/.test(value)) ccUuid = value;
      }
    } catch (_) {
      ccUuid = "";
    }
  }

  function readContextSnippet(prefix) {
    try {
      const fd = fs.openSync(path.join(plansDir, prefix + "-context.md"), "r");
      try {
        const buf = Buffer.alloc(CONTEXT_READ_CAP_BYTES);
        const n = fs.readSync(fd, buf, 0, CONTEXT_READ_CAP_BYTES, 0);
        return buf.slice(0, n).toString("utf8");
      } finally {
        fs.closeSync(fd);
      }
    } catch (_) {
      return "";
    }
  }

  const candidates = [];
  for (const entry of entries) {
    if (!entry.endsWith("-context.md")) continue;
    const prefix = entry.slice(0, -"-context.md".length);
    if (!/^[A-Za-z0-9_-]+$/.test(prefix)) continue;
    if (prefix.length < 8) continue;
    const dayPrefix = prefix.slice(0, 8);
    const dayIndex = allowedDateStrs.indexOf(dayPrefix);
    if (dayIndex < 0) continue;
    try {
      const mtimeMs = fs.statSync(path.join(plansDir, entry)).mtimeMs;
      let depth = 0;
      try {
        if (fs.existsSync(path.join(plansDir, prefix + "-detail.md"))) depth = 2;
        else if (fs.existsSync(path.join(plansDir, prefix + "-intent.md"))) depth = 1;
      } catch (_) {
        // stat error → fail-open (depth=0)
      }
      let ccBucket = 1;
      if (ccUuid) {
        const snippet = readContextSnippet(prefix);
        if (snippet && snippet.indexOf(ccUuid) !== -1) ccBucket = 0;
      }
      candidates.push({ sid: prefix, mtimeMs, depth, dayIndex, ccBucket });
    } catch (_) {
      // skip unreadable
    }
  }

  if (candidates.length === 0) return null;

  candidates.sort(
    (a, b) =>
      a.dayIndex - b.dayIndex ||
      a.ccBucket - b.ccBucket ||
      b.depth - a.depth ||
      b.mtimeMs - a.mtimeMs ||
      a.sid.localeCompare(b.sid)
  );
  return candidates[0].sid;
}

module.exports = { resolveWorkflowSessionId };
