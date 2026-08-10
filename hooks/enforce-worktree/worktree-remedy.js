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

function buildWorktreeRemedy(sessionId) {
  try {
    const { resolveSessionWorktreePath } = require("../workflow-state/resolve-worktree-path");
    const worktreePath = resolveSessionWorktreePath(sessionId);
    if (!worktreePath) return DEFAULT_REMEDY;
    return (
      `A linked worktree already exists for this session: ${worktreePath}\n` +
      "Enter it before writing — procedure: skills/_shared/worktree-transition.md\n"
    );
  } catch (_e) {
    return DEFAULT_REMEDY;
  }
}

module.exports = { buildWorktreeRemedy, DEFAULT_REMEDY };
