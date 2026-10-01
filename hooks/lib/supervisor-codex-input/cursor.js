"use strict";

// #2475 per-mode transcript cursor: {transcript_path, line, last_uuid, updated_at}.
// `line` counts complete ('\n'-terminated) lines already reviewed. Paths are
// normalized (toWindowsPath -> path.resolve) on store and compare, and compared
// case-insensitively on win32, so /c/x/t.jsonl and C:\X\T.jsonl are one path.

const path = require("path");
const { toWindowsPath } = require("../branch-diff");

function normalizePath(p) {
  return path.resolve(toWindowsPath(String(p)));
}

function samePath(a, b) {
  const na = normalizePath(a);
  const nb = normalizePath(b);
  return process.platform === "win32" ? na.toLowerCase() === nb.toLowerCase() : na === nb;
}

// entries: parsed JSONL objects per complete line (null for an unparsable line).
function lastUuid(entries, end) {
  for (let i = end - 1; i >= 0; i--) {
    const e = entries[i];
    if (e && typeof e.uuid === "string") return e.uuid;
  }
  return null;
}

function evaluate(cursor, transcriptPath, entries) {
  if (!cursor || typeof cursor !== "object") return { status: "fresh", start: 0 };
  if (typeof cursor.transcript_path !== "string" || !samePath(cursor.transcript_path, transcriptPath)) {
    return { status: "reset:path-changed", start: 0 };
  }
  const line = Number.isInteger(cursor.line) && cursor.line >= 0 ? cursor.line : 0;
  if (line > entries.length) return { status: "reset:truncated", start: 0 };
  const want = cursor.last_uuid === undefined ? null : cursor.last_uuid;
  if (lastUuid(entries, line) !== want) return { status: "reset:uuid-mismatch", start: 0 };
  return { status: "resume", start: line };
}

function next(transcriptPath, entries) {
  return {
    transcript_path: normalizePath(transcriptPath),
    line: entries.length,
    last_uuid: lastUuid(entries, entries.length),
    updated_at: new Date().toISOString(),
  };
}

module.exports = { evaluate, next, normalizePath, samePath };
