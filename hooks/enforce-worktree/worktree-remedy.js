"use strict";

// Remedy line for the main-worktree block reasons emitted by enforce-worktree.js (#1610).
//
// Text-level deferral only — the block verdict is never changed by this module.
// Default branch (no linked worktree resolvable for the session) keeps the current
// wording verbatim. When a linked worktree already exists, the transition procedure
// is deferred to the shared protocol fragment so the two PreToolUse hooks that can
// block the same call do not restate each other's diagnosis or steps.
//
// Any failure falls back to the default branch — never rethrows.

const DEFAULT_REMEDY = "Run: /worktree-start\n";

// worktreePath is resolved from a workflow-state file (resolveSessionWorktreePath
// only checks fs.existsSync), not a trusted constant — POSIX filesystems accept
// newlines, TABs and ESC in a directory name. Escape C0 controls (and DEL) to a
// printable \\uXXXX form so a crafted path cannot forge extra lines, ANSI escape
// sequences, or fake speaker turns in the reason text the model reads — the byte
// itself never reaches the decoded reason, only its textual name does. Ordinary
// paths (spaces, dots, parens, non-ASCII) contain none of these bytes and pass
// through unchanged.
const CONTROL_CHARS_RE = new RegExp("[\u0000-\u001f\u007f]", "g");
function escapeControlChar(ch) {
  return "\\u" + ch.codePointAt(0).toString(16).padStart(4, "0");
}
function neutralizeWorktreePath(rawPath) {
  return String(rawPath).replace(CONTROL_CHARS_RE, escapeControlChar);
}

function buildWorktreeRemedy(sessionId) {
  try {
    const { resolveSessionWorktreePath } = require("../workflow-state/resolve-worktree-path");
    const worktreePath = resolveSessionWorktreePath(sessionId);
    if (!worktreePath) return DEFAULT_REMEDY;
    const safePath = neutralizeWorktreePath(worktreePath);
    return (
      `A linked worktree already exists for this session: ${safePath}\n` +
      "Enter it before writing — procedure: skills/_shared/worktree-transition.md\n"
    );
  } catch (_e) {
    return DEFAULT_REMEDY;
  }
}

module.exports = { buildWorktreeRemedy, DEFAULT_REMEDY };
