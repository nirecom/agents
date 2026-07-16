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
 * Resolve the workflow session ID (wsid) — the timestamped session prefix used by
 * plan artifacts in WORKFLOW_PLANS_DIR (e.g. `<YYYYMMDD-HHMMSS>-intent.md`).
 * Distinct from resolveSessionId() which returns the CC session UUID.
 *
 * Priority chain:
 *   1. WORKTREE_NOTES.md Session-ID: line in CWD or git common-dir parent
 *      (written by /worktree-start — gold source).
 *   2. CLAUDE_CODE_SESSION_ID env var (charset-validated), if any
 *      `<value>-*.md` plan artifact exists in plans-dir. CC-native and reliably
 *      present in the Bash-tool path where CLAUDE_ENV_FILE is not propagated
 *      (#1082); existence-guarded to avoid resolving to an artifact-less session.
 *   3. CLAUDE_ENV_FILE -> CLAUDE_SESSION_ID value (charset-validated),
 *      if `<value>-intent.md` exists in plans-dir.
 *   4. Depth-score scan of `*-context.md` filenames in plans-dir, filtered by charset and
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

  // Priority 2: native CLAUDE_CODE_SESSION_ID (existence-guarded). CC-native,
  // per-session-distinct, present in the Bash-tool path where CLAUDE_ENV_FILE is
  // not propagated (#1082). Guard against selecting a session with no plan
  // artifacts yet (early-session false resolve) — accept only when any
  // `<value>-*.md` artifact exists in plans-dir.
  const codeSid = process.env.CLAUDE_CODE_SESSION_ID;
  if (codeSid && /^[A-Za-z0-9_-]+$/.test(codeSid.trim())) {
    const v = codeSid.trim();
    let hasArtifact = false;
    try {
      hasArtifact = fs
        .readdirSync(plansDir)
        .some((f) => f.startsWith(v + "-") && f.endsWith(".md"));
    } catch (_) {}
    if (hasArtifact) return v;
  }

  // Priority 3: CLAUDE_ENV_FILE → CLAUDE_SESSION_ID + intent.md existence check.
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

  // Priority 1d: sibling worktree scan. Reached only after Priority 1–3
  // (env-var-based) all fail. Own-worktree-first: identify the worktree root that
  // is CWD itself or an ancestor of CWD (so a CWD in a linked-worktree SUBDIR still
  // resolves to that worktree, not a sibling). If own's WORKTREE_NOTES.md yields a
  // Session-ID, it wins immediately. Only NON-own entries are collected as siblings;
  // multiple distinct sibling Session-IDs are ambiguous → null (fail-safe; do not
  // fall through to Priority 4).
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

  // Read CC UUID from CLAUDE_ENV_FILE (re-read for Priority 4 bucket-sort tie-break).
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
  if (!candidates.some(c => c.ccBucket === 0) && candidates.length > 1) {
    return null;
  }
  return candidates[0].sid;
}

module.exports = { resolveWorkflowSessionId };
