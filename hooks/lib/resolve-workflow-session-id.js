"use strict";

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
// CPR-SSOT (#2108): the WORKTREE_NOTES parser and the own-worktree matcher were
// private copies here and in workflow-state/session-id.js; both now share one.
const {
  readSessionIdFromWorktreeNotes,
  findOwnWorktreeDir,
  parseWorktreeDirs,
} = require("./worktree-notes-session-ids");

const PRIORITY3_DAYS_BACK = 2;
const CONTEXT_READ_CAP_BYTES = 16384;

/**
 * Resolve the workflow session ID (wsid) — the timestamped prefix plan artifacts in
 * WORKFLOW_PLANS_DIR use; distinct from resolveSessionId()'s CC UUID. Priority:
 * 1. WORKTREE_NOTES.md `Session-ID:` (CWD, then git common-dir parent).
 * 2. CLAUDE_CODE_SESSION_ID, guarded on a `<value>-*.md` artifact existing (#1082).
 * 3. Sibling-worktree scan. 4. Depth-score scan of recent `*-context.md`; a candidate
 * whose context.md contains CLAUDE_CODE_SESSION_ID wins, else several → null.
 * Returns null on any failure (no throw). See session-id-resolution.md.
 */
function resolveWorkflowSessionId(ctx = {}) {
  const { getWorkflowPlansDir } = require("./workflow-plans-dir");
  let plansDir;
  try {
    plansDir = getWorkflowPlansDir();
  } catch (_) {
    return null;
  }

  // Priority 1: WORKTREE_NOTES.md Session-ID (written by /worktree-start — gold source).
  const fromCwd = readSessionIdFromWorktreeNotes(
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
      const fromGit = readSessionIdFromWorktreeNotes(
        path.join(path.resolve(commonDir), "..", "WORKTREE_NOTES.md")
      );
      if (fromGit) return fromGit;
    }
  } catch (_) {}

  // CC-native id, read once: Priority 2 and the Priority 4 tie-break both use it.
  const nativeSid = (() => {
    const v = (process.env.CLAUDE_CODE_SESSION_ID || "").trim();
    return /^[A-Za-z0-9_-]+$/.test(v) ? v : "";
  })();

  // Priority 2: native CLAUDE_CODE_SESSION_ID (existence-guarded). Guard against
  // selecting a session with no plan artifacts yet (early-session false resolve) —
  // accept only when any `<value>-*.md` artifact exists in plans-dir.
  if (nativeSid) {
    const v = nativeSid;
    let hasArtifact = false;
    try {
      hasArtifact = fs
        .readdirSync(plansDir)
        .some((f) => f.startsWith(v + "-") && f.endsWith(".md"));
    } catch (_) {}
    if (hasArtifact) return v;
  }

  // Priority 1d: sibling worktree scan. Reached only after Priority 1–2
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

  // CC UUID tie-break input is the native id (the same value Priority 2 checked).
  const ccUuid = nativeSid;

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
