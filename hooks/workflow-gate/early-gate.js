"use strict";
// hooks/workflow-gate/early-gate.js
// EARLY GATE: 3-tier enforcement before Edit/Write tools.
// Extracted from hooks/workflow-gate.js (file-split HARD limit).
//
//   Tier 1: workflow_init must be complete/skipped first.
//   Tier 2: clarify_intent must be complete/skipped (only checked once Tier 1 clears).
//   Tier 3: session-bound worktree exists but CWD is outside it (worktree-entry-gate.js).
// Fail-open precedence (do NOT reorder):
//   1. No sessionId → fall through (cannot enforce)
//   2. readState() returns null → fall through (no state to check)
//   3. plans-path Write/Edit/MultiEdit allowlist → fall through (skill output path)
//   4. Tier 1 not clear → block (references /workflow-init)
//   5. Tier 2 not clear → block (references /clarify-intent)
//   6. Both clear → fall through (gate dormant)
//   7. Tier 3 predicate false or throws → fall through (gate dormant)
//
// Multi-hook execution: Claude Code runs all PreToolUse hooks independently;
// approve from this hook does NOT short-circuit block-dotenv etc.
//
// Deferral contract with enforce-worktree.js: the "worktree exists but the session
// is not inside it" diagnosis is owned here; enforce-worktree.js keeps its own
// main-worktree block verdict unchanged and only swaps its remedy line (#1610).
//
// State inheritance: if findLatestStateForContext() inherited a state where both
// steps are already complete, gate is dormant by design — inherited state represents
// continuing prior work.

const path = require("path");
const { readState, reconcileEffectiveState } = require("../workflow-state");
const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");

const EARLY_GATE_TOOLS = new Set([
  "Edit", "Write", "MultiEdit", "editFiles", "NotebookEdit"
]);

// Runs the early gate for one hook invocation.
// `block` is injected by workflow-gate.js (owns the hook stdout protocol + supervisor report).
function runEarlyGate(input, { block }) {
  const toolName = input.tool_name;
  const toolInput = input.tool_input || {};
  const sessionId = input.session_id;

  if (!sessionId || !EARLY_GATE_TOOLS.has(toolName)) return;
  const earlyState = readState(sessionId);
  if (!earlyState) return;

  // Plans-path allowlist: Write/Edit/MultiEdit tools, targeting ~/.workflow-plans/**
  // (skill writes intent/outline/detail .md here while workflow_init is still pending).
  // Resolve the path so traversal sequences like "../" can't smuggle the write outside.
  const filePath = toolInput.file_path || toolInput.path || "";
  let isPlansAllowed = false;
  if ((toolName === "Write" || toolName === "Edit" || toolName === "MultiEdit") && filePath) {
    try {
      const resolved = path.resolve(filePath);
      const plansRoot = path.resolve(getWorkflowPlansDir()) + path.sep;
      isPlansAllowed = resolved.toLowerCase().startsWith(plansRoot.toLowerCase());
    } catch (e) { console.error(`workflow-gate: ${e.message}`); }
  }
  if (isPlansAllowed) return;

  // Derived view (#1681): Tier 1/Tier 2 read the reconciled snapshot, not the
  // raw record — so evidence-resolved steps clear the gate without the gate
  // ever writing state back (Approach B replaces the old #1094 self-repair
  // markStep).
  // Security: no repoDir here — the early gate only reads workflow_init and
  // clarify_intent, neither of which uses repoDir for evidence. Supplying
  // toolInput.cwd would route git execs into an unvalidated path (#H1).
  // Fail-closed: snapshot failure falls back to raw state, not "complete" (#H2).
  let earlySnapshot = null;
  try {
    earlySnapshot = reconcileEffectiveState(earlyState, sessionId, {
      isWfMeta: earlyState.workflow_type === "wf-meta",
      evidencePolicy: "staged-only",
    });
  } catch (e) { earlySnapshot = null; }
  const earlyStatus = (step) => {
    if (!earlySnapshot || !earlySnapshot.steps) {
      // Fall back to raw state on error (fail-closed, matching the commit gate).
      return (earlyState && earlyState.steps && earlyState.steps[step] || {}).status || "pending";
    }
    return (earlySnapshot.steps[step] || {}).status || "pending";
  };

  // Tier 1: workflow_init
  const wiStatus = earlyStatus("workflow_init");
  if (wiStatus !== "complete" && wiStatus !== "skipped") {
    block(
      "workflow-gate: workflow_init has not been completed for this session.\n" +
      "Tool \"" + toolName + "\" is blocked until the workflow is routed.\n\n" +
      "To complete:\n" +
      "  1. Invoke the `workflow-init` skill via the Skill tool, OR\n" +
      "  2. For docs-only edits: echo \"<<WORKFLOW_MARK_STEP_workflow_init_complete>>\".\n\n" +
      "Note: Read, Grep, Glob, Bash, and AskUserQuestion remain available.\n\n" +
      "To reset workflow state: echo \"<<WORKFLOW_RESET_FROM_workflow_init: {reason}>>\""
    );
  }
  // Tier 2: clarify_intent (only reached once workflow_init has cleared).
  // The #1094 evidence self-repair is now derivation, not a write: an
  // existing intent.md already resolves clarify_intent to complete inside
  // the snapshot, so the gate simply reads it and stays dormant.
  const ciStatus = earlyStatus("clarify_intent");
  if (ciStatus !== "complete" && ciStatus !== "skipped") {
    block(
      "workflow-gate: clarify_intent has not been completed for this session.\n" +
      "Tool \"" + toolName + "\" is blocked until intent is locked in.\n\n" +
      "To complete:\n" +
      "  1. Invoke the `clarify-intent` skill via the Skill tool, OR\n" +
      "  2. If intent is already clear: echo \"<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: {reason}>>>\".\n\n" +
      "Note: Read, Grep, Glob, Bash, and AskUserQuestion remain available.\n" +
      "For docs-only edits: echo \"<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: docs-only edit>>\"\n\n" +
      "To reset workflow state: echo \"<<WORKFLOW_RESET_FROM_clarify_intent: {reason}>>\""
    );
  }
  // Tier 3: session-bound worktree exists but CWD is outside it (#1610).
  try {
    const { evaluateWorktreeEntry, buildBlockReason } = require("./worktree-entry-gate");
    const wtVerdict = evaluateWorktreeEntry({ sessionId, input, toolName, toolInput, state: earlyState });
    if (wtVerdict && wtVerdict.verdict === "advisory") {
      process.stderr.write(
        `workflow-gate: session worktree ${wtVerdict.worktreePath} was never entered (subagent context) — proceeding.\n`
      );
    } else if (wtVerdict && wtVerdict.verdict === "block") {
      block(buildBlockReason({
        toolName,
        worktreePath: wtVerdict.worktreePath,
        cwd: wtVerdict.cwd,
      }));
    }
  } catch (e) { /* fail-open: Tier 3 dormant */ }
}

module.exports = { runEarlyGate, EARLY_GATE_TOOLS };
