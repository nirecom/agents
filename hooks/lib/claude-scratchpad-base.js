"use strict";
// hooks/lib/claude-scratchpad-base.js
// SSOT for the session-scratchpad allowlist base (<os-tmpdir>/claude).
// F1 (TEMP/TMP poisoning): os.tmpdir() reads TEMP/TMP/TMPDIR, so a poisoned value
//   can land the claude base INSIDE a repo — every allow decision built on this
//   base must ALSO confirm the candidate is not inside any repo root
//   (isRepoExcluded / isAllowedScratchpadTarget below).
// H2 (session scoping): with SCRATCHPAD exposed and resolving under the base, the
//   allow root tightens to that directory. The WRITE path falls back to the whole
//   base when SCRATCHPAD is absent; the EXEC path (getCurrentSessionScratchpadRootNorm)
//   never does — see docs/architecture/claude-code/settings.md.

const fs = require("fs");
const path = require("path");
const os = require("os");

// POSIX case sensitivity: fold case only on Windows (case-insensitive filesystem).
// On POSIX, lowercase-folding would wrongly equate /tmp/CLAUDE with /tmp/claude —
// two distinct directories.
function foldCase(s) {
  return process.platform === "win32" ? s.toLowerCase() : s;
}

// Resolve the normalized (case-folded) claude scratchpad base — single source of truth.
function getClaudeBaseNorm() {
  return foldCase(path.resolve(path.join(os.tmpdir(), "claude")));
}

// True if `p` resolves STRICTLY under <os-tmpdir>/claude/ (never the base itself).
function isUnderClaudeBase(p) {
  const normBase = getClaudeBaseNorm();
  const n = foldCase(path.resolve(p));
  return n.startsWith(normBase + path.sep) || n.startsWith(normBase + "/");
}

// True if `p` resolves to the claude base itself OR under it.
function isAtOrUnderClaudeBase(p) {
  const normBase = getClaudeBaseNorm();
  const n = foldCase(path.resolve(p));
  return n === normBase || n.startsWith(normBase + path.sep) || n.startsWith(normBase + "/");
}

// H2: resolve the allowlist root — the current session's scratchpad dir when the
// harness exposes it (SCRATCHPAD env var, validated at-or-under the claude base),
// else the whole claude base (fallback).
function getScratchpadAllowRootNorm() {
  const base = getClaudeBaseNorm();
  const sp = process.env.SCRATCHPAD;
  if (sp) {
    try {
      const n = foldCase(path.resolve(sp));
      if (n === base || n.startsWith(base + path.sep) || n.startsWith(base + "/")) return n;
    } catch (_) { /* fall back to base */ }
  }
  return base;
}

// Symlink-resolving twin of isUnderClaudeBase, for the EXEC path only: that path's
// containment window is realpath-based, so a root that merely LOOKS in-base while
// linking outside would relocate the window onto the link's external target.
// Throws propagate — the caller treats them as fail-to-ask.
function realIsUnderClaudeBase(p) {
  const realBase = foldCase(fs.realpathSync(getClaudeBaseNorm()));
  const n = foldCase(fs.realpathSync(p));
  return n.startsWith(realBase + path.sep) || n.startsWith(realBase + "/");
}

// F1 clause, shared by the write path below and the exec path in
// hooks/preuse-auto-approve/scratchpad-script.js: `findRepoRoot` is injected
// because the module layout differs per call site.
function isRepoExcluded(candidatePath, findRepoRoot) {
  return typeof findRepoRoot === "function" && findRepoRoot(candidatePath) !== null;
}

// The EXEC-path allow root, deliberately narrower than the write path: exactly one
// of {kind:"path", root} (SCRATCHPAD strictly under the base), {kind:"session",
// sessionId} (caller does the structural match — the project-slug derivation is an
// internal Claude Code detail with no SSOT here), or null. null means FAIL-TO-ASK:
// the caller must never substitute a wider fallback root.
function getCurrentSessionScratchpadRootNorm() {
  const sp = process.env.SCRATCHPAD;
  if (sp) {
    try {
      if (isUnderClaudeBase(sp) && realIsUnderClaudeBase(sp)) {
        return { kind: "path", root: foldCase(path.resolve(sp)) };
      }
    } catch (_) { /* fall through to the session-id shape */ }
  }
  const sessionId = process.env.CLAUDE_SESSION_ID;
  if (typeof sessionId === "string" && sessionId.trim() !== "") {
    return { kind: "session", sessionId: sessionId.trim() };
  }
  return null;
}

// F1 + H2 hardening: a target is an accepted scratchpad write ONLY when it
// resolves STRICTLY under the session-scoped allow root AND is not inside any git
// repo root. Fail-closed on any detection error.
function isAllowedScratchpadTarget(resolvedPath, findRepoRoot) {
  try {
    const allowRoot = getScratchpadAllowRootNorm();
    const n = foldCase(path.resolve(resolvedPath));
    if (!n.startsWith(allowRoot + path.sep) && !n.startsWith(allowRoot + "/")) return false;
    if (isRepoExcluded(resolvedPath, findRepoRoot)) return false;
  } catch (_) {
    return false; // fail-closed on any detection error
  }
  return true;
}

module.exports = {
  foldCase,
  getClaudeBaseNorm,
  isUnderClaudeBase,
  isAtOrUnderClaudeBase,
  getScratchpadAllowRootNorm,
  getCurrentSessionScratchpadRootNorm,
  isRepoExcluded,
  isAllowedScratchpadTarget,
};
