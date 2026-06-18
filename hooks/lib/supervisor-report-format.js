"use strict";

const path = require("path");

// Pure-function formatter for EM Supervisor Layer 2 block reasons.
// Used by hooks/supervisor-guard.js branches (2) cumSev=error and
// (3) l2ArmedAt / sentinel-hang. No side effects; receives pre-populated
// data from the guard.

function wsidLabel(workflowSessionId) {
  return workflowSessionId == null ? "UNAVAILABLE" : workflowSessionId;
}

function aggregateCategories(findings) {
  const seen = new Set();
  const out = [];
  for (const f of findings) {
    if (!f || !Array.isArray(f.categories)) continue;
    for (const c of f.categories) {
      if (typeof c === "string" && !seen.has(c)) {
        seen.add(c);
        out.push(c);
      }
    }
  }
  return out;
}

// SSOT for the L2 fallback recipe block — shown on every block reason so
// the user (or the supervisor subagent itself) can self-recover from an
// API-error retry loop by freezing the session deterministically.
function recipeBlock(sessionId, stateFilePath) {
  return [
    "Fallback (if the supervisor subagent invocation fails with an API error):",
    `  Run: bin/supervisor-write-layer2 --clear-l2-armed-at --set-l2-phase frozen --session-id ${sessionId}`,
    "  This freezes the L2 review for this session so the loop terminates. l2_phase=frozen is terminal.",
    `  State file: ${stateFilePath}`,
  ];
}

function formatCumSevErrorReason(findings, sessionId, workflowSessionId, supervisorPath, stateFilePath) {
  const lines = [];
  lines.push("[EM Supervisor] Layer 2: cumulative_severity=error.");

  if (!Array.isArray(findings) || findings.length === 0) {
    lines.push("Categories: (none)");
    lines.push("Detail: (no findings recorded)");
    lines.push(`Session ID: ${sessionId}`);
    lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
    for (const l of recipeBlock(sessionId, stateFilePath)) lines.push(l);
    lines.push(`Recommended action: follow agents/supervisor.md (${supervisorPath}) to resolve before continuing.`);
    return lines.join("\n");
  }

  const allCats = aggregateCategories(findings);
  lines.push(`Categories: ${allCats.length > 0 ? allCats.join(", ") : "(none)"}`);

  lines.push("Findings:");
  for (let i = 0; i < findings.length; i++) {
    const f = findings[i];
    if (!f) continue;
    const cats = Array.isArray(f.categories) ? f.categories.join(", ") : "(none)";
    const detail = typeof f.detail === "string" ? f.detail : "(no detail)";
    lines.push(`  [${i + 1}] categories=${cats} severity=${f.severity || "(none)"} detail=${detail}`);
  }

  const last = findings[findings.length - 1];
  const lastDetail = last && typeof last.detail === "string" ? last.detail : "(no detail)";
  lines.push(`Detail: ${lastDetail}`);
  lines.push(`Session ID: ${sessionId}`);
  lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
  for (const l of recipeBlock(sessionId, stateFilePath)) lines.push(l);
  lines.push(`Recommended action: follow agents/supervisor.md (${supervisorPath}) to resolve before continuing.`);
  return lines.join("\n");
}

function formatL2ArmedReason(cause, sessionId, workflowSessionId, supervisorPath, stateFilePath) {
  const lines = [];
  const isC1 = typeof cause === "string" && cause.indexOf("C1") === 0;
  const isC3 = typeof cause === "string" && cause.indexOf("C3") === 0;
  const causeLabel = isC1
    ? "C1 stop_hook_active sentinel hang detected"
    : isC3
    ? `C3 off-proposal detected (${cause})`
    : "C2 scheduled review";

  lines.push(`[EM Supervisor] Layer 2 review required (${causeLabel}).`);
  if (isC1) {
    lines.push("Trigger: stop_hook_active sentinel hang detected in the assistant transcript.");
  } else if (isC3) {
    const proposalType = cause.includes("worktree-off") ? "WORKTREE_OFF" : "WORKFLOW_OFF";
    lines.push(`Trigger: assistant output contained a ${proposalType} proposal sentinel (<<WORKFLOW_ENFORCE_${proposalType}>>).`);
    lines.push(`Verify: check whether this was a sanctioned use per rules/workflow-off.md "Sanctioned-command false-block recovery". If so, the session can continue; if improvised bypass, recommend reverting.`);
  } else {
    lines.push("Trigger: scheduled Layer 2 review (l2_armed_at set).");
  }
  lines.push(`Action: invoke agents/supervisor.md (${supervisorPath}) as a subagent - run the JD checklist, provide first-aid guidance, then recommend /issue-create for root-cause fix.`);
  lines.push("To resume: clear the l2_armed_at field in the supervisor state file after the review is complete.");
  lines.push(`Clear: set layer2.l2_armed_at = null in the state file.`);
  lines.push(`File: ${stateFilePath}`);
  const writerPath = path.resolve(__dirname, "supervisor-state-writer");
  lines.push(`Equivalent one-liner: node -e "require('${writerPath}').writeLayer2State('${sessionId}', {l2_armed_at: null})"`);
  for (const l of recipeBlock(sessionId, stateFilePath)) lines.push(l);
  lines.push(`Session ID: ${sessionId}`);
  lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
  return lines.join("\n");
}

function formatWorktreeOffProposalReason(sessionId, workflowSessionId, supervisorPath, stateFilePath) {
  const lines = [];
  lines.push("[EM Supervisor] C3: WORKTREE_OFF proposal pre-detected.");
  lines.push(`Action: invoke agents/supervisor.md (${supervisorPath}) as a subagent to review the worktree-off proposal.`);
  for (const l of recipeBlock(sessionId, stateFilePath)) lines.push(l);
  lines.push(`Session ID: ${sessionId}`);
  lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
  return lines.join("\n");
}

module.exports = { formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason };
