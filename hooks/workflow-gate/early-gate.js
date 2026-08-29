"use strict";
// hooks/workflow-gate/early-gate.js
// EARLY GATE: 3-tier enforcement before Edit/Write tools (Tier 1 workflow_init,
// Tier 2 clarify_intent, Tier 3 worktree entry via ./worktree-entry-gate).
//
// Fail-open precedence (do NOT reorder): no sessionId → readState() null →
// the write allowlist (./early-gate-allowlist) → Tier 1 block → Tier 2 block →
// both clear → Tier 3. Claude Code runs every PreToolUse hook independently, so
// falling through here does not short-circuit any other hook. The "worktree
// exists but the session is not inside it" diagnosis is owned here (#1610), and
// inherited complete state leaves the gate dormant by design (#1305).

const { readState, reconcileEffectiveState } = require("../workflow-state");
const { classifyEarlyWriteAllow, describeAllowedTargets } = require("./early-gate-allowlist");
const { buildEarlyGateReason } = require("./early-gate-messages");
const { isSubagentCall } = require("../lib/subagent-detect");

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

  // Write allowlist (#2108): the plans dir AND the session scratchpad. Both
  // destinations sit outside the repo and outside workflow state, so a write
  // there cannot pre-empt the routing this gate is protecting — while a gate with
  // no legal write target leaves a subagent nothing to do but hunt for a bypass.
  if (classifyEarlyWriteAllow(toolName, toolInput) !== null) return;

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

  // The VERDICT never branches on caller identity — only the REMEDY does
  // (./early-gate-messages), so a subagent is told what it can actually do.
  const isSubagent = isSubagentCall(input);
  const allowedTargets = describeAllowedTargets();

  // Tier 1: workflow_init
  const wiStatus = earlyStatus("workflow_init");
  if (wiStatus !== "complete" && wiStatus !== "skipped") {
    block(buildEarlyGateReason({ tier: "workflow_init", toolName, isSubagent, allowedTargets }));
  }
  // Tier 2: clarify_intent (only reached once workflow_init has cleared).
  // The #1094 evidence self-repair is now derivation, not a write: an
  // existing intent.md already resolves clarify_intent to complete inside
  // the snapshot, so the gate simply reads it and stays dormant.
  const ciStatus = earlyStatus("clarify_intent");
  if (ciStatus !== "complete" && ciStatus !== "skipped") {
    block(buildEarlyGateReason({ tier: "clarify_intent", toolName, isSubagent, allowedTargets }));
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
