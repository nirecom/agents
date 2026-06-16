"use strict";

const fs = require("fs");
const path = require("path");

/**
 * Resolve the workflow session ID (wsid) — the timestamped session prefix used by
 * plan artifacts in WORKFLOW_PLANS_DIR (e.g. `<YYYYMMDD-HHMMSS>-intent.md`).
 * Distinct from resolveSessionId() which returns the CC session UUID.
 *
 * Priority chain:
 *   1. CLAUDE_ENV_FILE -> CLAUDE_SESSION_ID value (charset-validated),
 *      if `<value>-intent.md` exists in plans-dir.
 *   2. mtime scan of `*-context.md` filenames in plans-dir, filtered by charset and
 *      same-day date-sanity (prefix must start with today's local YYYYMMDD).
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
  const todayStr =
    String(now.getFullYear()) +
    String(now.getMonth() + 1).padStart(2, "0") +
    String(now.getDate()).padStart(2, "0");

  const candidates = [];
  for (const entry of entries) {
    if (!entry.endsWith("-context.md")) continue;
    const prefix = entry.slice(0, -"-context.md".length);
    if (!/^[A-Za-z0-9_-]+$/.test(prefix)) continue;
    if (prefix.length < 8 || prefix.slice(0, 8) !== todayStr) continue;
    try {
      const mtimeMs = fs.statSync(path.join(plansDir, entry)).mtimeMs;
      candidates.push({ sid: prefix, mtimeMs });
    } catch (_) {
      // skip unreadable
    }
  }

  if (candidates.length === 0) return null;

  candidates.sort((a, b) => b.mtimeMs - a.mtimeMs || a.sid.localeCompare(b.sid));
  return candidates[0].sid;
}

module.exports = { resolveWorkflowSessionId };
