"use strict";
// Temporary (#1091): deleted with its migration block in hooks/session-start.js.
// Removes the lines the retired relay appended (exact shape `CLAUDE_SESSION_ID=<id>`)
// from THIS session's CLAUDE_ENV_FILE; never creates, never touches other lines.
const fs = require("fs");
const { toWindowsPath } = require("../branch-diff");

const RELAY_LINE_RE = /^CLAUDE_SESSION_ID=[A-Za-z0-9_-]*\r?$/;

function purgeLegacyRelayLines(envFile = process.env.CLAUDE_ENV_FILE) {
  if (typeof envFile !== "string" || envFile === "") return { changed: false };
  const p = toWindowsPath(envFile);
  let content;
  try { content = fs.readFileSync(p, "utf8"); }
  catch (_) { return { changed: false }; }
  const parts = content.split(/(?<=\n)/);
  const kept = parts.filter((l) => !RELAY_LINE_RE.test(l.replace(/\n$/, "")));
  if (kept.length === parts.length) return { changed: false };
  // In place (no temp+rename): Claude Code owns the path, mode and inode.
  try { fs.writeFileSync(p, kept.join(""), "utf8"); }
  catch (_) {
    // A failed truncating write can leave the file short; restore the original bytes.
    try { fs.writeFileSync(p, content, "utf8"); } catch (_e) { /* best effort */ }
    return { changed: false };
  }
  return { changed: true, removed: parts.length - kept.length };
}

module.exports = { purgeLegacyRelayLines, RELAY_LINE_RE };
