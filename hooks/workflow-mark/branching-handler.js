"use strict";
// Handles BRANCHING_COMPLETE (and legacy BRANCHING_DECIDED) sentinels, emitted
// when the worktree/branch setup step finishes. Marks branching_complete in workflow state.

const fs = require("fs");
const { validateSkipReason } = require("./skip-reason");
const {
  markStep, recordSessionWorktree, readState, recordMergeBaseBaseline,
} = require("../workflow-state");
const { isMainWorktree } = require("../workflow-state/resolve-worktree-path");
const {
  BRANCHING_COMPLETE_RE_DQ, BRANCHING_COMPLETE_LOOKSLIKE_RE,
  BRANCHING_DECIDED_RE_DQ, BRANCHING_DECIDED_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  // Accept both new (BRANCHING_COMPLETE) and legacy (BRANCHING_DECIDED) sentinel.
  const branchingDecidedMatch =
    cmd.match(BRANCHING_COMPLETE_RE_DQ) || cmd.match(BRANCHING_DECIDED_RE_DQ);
  const branchingDecidedLooksLike =
    !branchingDecidedMatch &&
    (BRANCHING_COMPLETE_LOOKSLIKE_RE.test(cmd) || BRANCHING_DECIDED_LOOKSLIKE_RE.test(cmd));

  // --- BRANCHING_COMPLETE handler (also accepts legacy BRANCHING_DECIDED) ---
  if (branchingDecidedLooksLike) {
    pushMessage(
      `workflow-mark: malformed BRANCHING_COMPLETE — ` +
        `expected: echo "<<WORKFLOW_BRANCHING_COMPLETE: DECISION>>" ` +
        `(decision must be >=3 non-space chars, no '>')`
    );
    return true;
  }
  if (branchingDecidedMatch) {
    const v = validateSkipReason(branchingDecidedMatch[1]);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: BRANCHING_COMPLETE rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_BRANCHING_COMPLETE: {decision}>>"`
      );
      return true;
    }
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — branching_complete NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_BRANCHING_COMPLETE: ${v.reason}>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "branching_complete", "complete", { decision: v.reason });
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. branching_complete NOT recorded.`
      );
    }
    try {
      const wtMatch = v.reason.match(/\bworktree:\s*([^\s|]+)/);
      const wtPath = wtMatch ? wtMatch[1] : null;
      if (wtPath && fs.existsSync(wtPath) && !isMainWorktree(wtPath)) {
        recordSessionWorktree(sessionId, wtPath);
      } else {
        recordSessionWorktree(sessionId, null);
      }
    } catch (e) {
      pushMessage(`workflow-mark: warning — failed to record session_worktree: ${e.message}`);
    }
    // The session's merge-base baseline. This is the ONE automatic writer (#1638): the branch
    // point is a fact right now and a guess forever after, so it is recorded here.
    //
    // Its own try/catch, and pushMessage rather than signalFatal on failure: a missing
    // baseline degrades the later gates to guessing, which is exactly what they did before.
    // Aborting the user's step over a lost optimisation would be a worse outcome than the
    // problem. A session working directly in state.cwd (no `worktree:` segment) gets a
    // baseline too — otherwise every main-worktree session silently records nothing.
    try {
      const wtMatch = v.reason.match(/\bworktree:\s*([^\s|]+)/);
      const wtPath = wtMatch ? wtMatch[1] : null;
      let repoRoot = null;
      if (wtPath && fs.existsSync(wtPath)) {
        repoRoot = wtPath;
      } else {
        const state = readState(sessionId);
        repoRoot =
          (state && typeof state.cwd === "string" && state.cwd) ||
          process.env.CLAUDE_PROJECT_DIR ||
          process.cwd();
      }
      const res = recordMergeBaseBaseline(sessionId, repoRoot);
      if (res && !res.recorded && res.reason && !/write-once/.test(res.reason)) {
        pushMessage(`workflow-mark: warning — merge-base baseline not recorded: ${res.reason}`);
      }
    } catch (e) {
      pushMessage(`workflow-mark: warning — failed to record the merge-base baseline: ${e.message}`);
    }
    return true;
  }

  return false;
}

module.exports = { handle };
