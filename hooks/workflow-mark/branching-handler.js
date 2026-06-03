"use strict";
// Handles BRANCHING_COMPLETE (and legacy BRANCHING_DECIDED) sentinels, emitted
// when the worktree/branch setup step finishes. Marks branching_complete in workflow state.

const { validateSkipReason } = require("./skip-reason");
const { markStep, nextStepHint } = require("../lib/workflow-state");
const {
  BRANCHING_COMPLETE_RE_DQ, BRANCHING_COMPLETE_LOOKSLIKE_RE,
  BRANCHING_DECIDED_RE_DQ, BRANCHING_DECIDED_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

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
          `Re-run: echo "<<WORKFLOW_BRANCHING_COMPLETE: <decision>>"`
      );
      return true;
    }
    if (!sessionId) {
      pushMessage(
        `workflow-mark: could not resolve session_id — branching_complete NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_BRANCHING_COMPLETE: ${v.reason}>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "branching_complete", "complete", { decision: v.reason });
      const hint = nextStepHint("branching_complete");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. branching_complete NOT recorded.`
      );
    }
    return true;
  }

  return false;
}

module.exports = { handle };
