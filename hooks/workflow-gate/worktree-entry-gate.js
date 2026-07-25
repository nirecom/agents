"use strict";

// Tier 3 predicate for the hooks/workflow-gate.js EARLY GATE (#1610).
//
// Semantics: once branching_complete is recorded and a linked worktree exists for
// the session, an EARLY_GATE_TOOLS write is blocked whenever the session's current
// working directory is outside that worktree — regardless of where the write lands.
// The incident being prevented is "work proceeds without the session worktree
// binding", not "a file lands in the wrong place"; a write aimed at an absolute
// path inside the worktree establishes no binding at all, so it is blocked too.
//
// The destination path deliberately does NOT participate in the decision.
// Past transition records (e.g. state.worktree_entered_at) deliberately do NOT
// participate either: current-location evidence is never overridden by a record
// that may have gone stale.
//
// Fail-open: every predicate failure and every thrown error collapses to "dormant".

const path = require("path");

// True when `childAbs` resolves to `parentAbs` itself or something under it.
// Case-insensitive on win32, where the same path can differ only in case.
function isUnder(childAbs, parentAbs) {
  let c = path.resolve(childAbs);
  let p = path.resolve(parentAbs);
  if (!c.endsWith(path.sep)) c += path.sep;
  if (!p.endsWith(path.sep)) p += path.sep;
  if (process.platform === "win32") {
    c = c.toLowerCase();
    p = p.toLowerCase();
  }
  return c.startsWith(p);
}

// evaluateWorktreeEntry({ sessionId, input, toolName, toolInput, state })
//   → { verdict: "dormant" | "advisory" | "block", worktreePath?, cwd? }
function evaluateWorktreeEntry({ sessionId, input, toolName, toolInput, state } = {}) {
  try {
    // c1 — enforcement enabled. workflow-gate.js does not load .env itself.
    try { require("../lib/load-env").loadDefaultEnv(); } catch (_e) { /* fail-open */ }
    if (!require("../enforce-worktree/config").isEnforceWorktreeOn()) return { verdict: "dormant" };

    // c2 — session-scoped WORKTREE_OFF marker.
    if (require("../lib/session-markers").isWorktreeOff(sessionId)) return { verdict: "dormant" };

    // c3 — branching_complete actually complete (skipped / pending / missing → dormant).
    if (!state || !state.steps) return { verdict: "dormant" };
    const bc = state.steps.branching_complete;
    if (!bc || bc.status !== "complete") return { verdict: "dormant" };

    // c4 — an existing linked worktree is recorded for this session.
    const { resolveSessionWorktreePath } = require("../lib/workflow-state/resolve-worktree-path");
    const worktreePath = resolveSessionWorktreePath(sessionId);
    if (!worktreePath) return { verdict: "dormant" };

    // c5 — current location is knowable.
    if (!input || typeof input.cwd !== "string") return { verdict: "dormant" };
    const cwd = require("../lib/path-normalize").normalizeCwd(input.cwd);
    if (!cwd) return { verdict: "dormant" };

    // c6 — current location is outside the worktree.
    if (isUnder(cwd, worktreePath)) return { verdict: "dormant" };

    // Subagent / headless contexts cannot perform an interactive entry; blocking
    // them would be unrecoverable, so they are downgraded to advisory.
    const verdict = require("../lib/subagent-detect").isSubagentCall(input) ? "advisory" : "block";
    return { verdict, worktreePath: path.resolve(worktreePath), cwd: path.resolve(cwd) };
  } catch (_e) {
    return { verdict: "dormant" };
  }
}

// Block reason owned by this gate. It states the diagnosis and the escape hatches;
// the transition procedure itself belongs to the shared protocol fragment.
function buildBlockReason({ toolName, worktreePath, cwd } = {}) {
  return [
    "workflow-gate: this session created a linked worktree but the current working directory is outside it.",
    "Tool \"" + toolName + "\" is blocked to prevent work proceeding without the session worktree binding.",
    "Session worktree: " + worktreePath,
    "Current directory: " + cwd,
    "Writing to a path inside the worktree does not establish the binding — enter the worktree itself.",
    "Procedure: skills/_shared/worktree-transition.md",
    "Note: Read, Grep, Glob, Bash, and AskUserQuestion remain available.",
    "Escape hatches: echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: {reason}>>\" or echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>\"",
  ].join("\n");
}

module.exports = { evaluateWorktreeEntry, buildBlockReason };
