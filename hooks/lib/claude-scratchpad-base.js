"use strict";
// hooks/lib/claude-scratchpad-base.js
// SSOT for the session-scratchpad allowlist base (<os-tmpdir>/claude).
//
// Security notes:
// F1 (TEMP/TMP poisoning): os.tmpdir() reads the TEMP/TMP/TMPDIR environment
//   variables. A poisoned TEMP (e.g. TEMP=C:/git/agents) would make the derived
//   claude base fall INSIDE the repo, so a naive prefix check on "<base>/claude/**"
//   could allow an in-repo write. All allow decisions that rely on this base MUST
//   additionally confirm the candidate target is NOT inside any repo root (via
//   findRepoRoot) — see isAllowedScratchpadTarget below.
// H2 (session scoping): when the harness exposes the current session's scratchpad
//   dir via the SCRATCHPAD env var (and it resolves under the claude base), the
//   allowlist root tightens to THAT directory — cross-session scratchpad writes are
//   rejected. When SCRATCHPAD is not available, the root falls back to the whole
//   claude base (accepted cross-session breadth in the fallback), still guarded by
//   the F1 repo-exclusion clause.
// Symlink residual: prefix checks are lexical — a symlink/junction planted under the
//   allowed root could redirect a write elsewhere. This latent gap also exists in the
//   pre-existing plans-dir predicate and is tracked as pre-existing (out of scope here).

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

// F1 + H2 hardening: a target is an accepted scratchpad write ONLY when:
//   1. it resolves STRICTLY under the session-scoped allow root (H2); and
//   2. it does NOT resolve inside any git repo root (F1 — defeats a poisoned TEMP
//      that nests the claude base inside a repo tree).
// `findRepoRoot` is injected by the caller (module layout differs per call site).
// Fail-closed on any detection error.
function isAllowedScratchpadTarget(resolvedPath, findRepoRoot) {
  try {
    const allowRoot = getScratchpadAllowRootNorm();
    const n = foldCase(path.resolve(resolvedPath));
    if (!n.startsWith(allowRoot + path.sep) && !n.startsWith(allowRoot + "/")) return false;
    if (typeof findRepoRoot === "function" && findRepoRoot(resolvedPath) !== null) return false;
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
  isAllowedScratchpadTarget,
};
