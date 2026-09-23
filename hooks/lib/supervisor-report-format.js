"use strict";

const path = require("path");
const { getConvLangInjection } = require("./conv-lang");

// Pure-function formatter for EM Supervisor alert/audit block reasons.
// Used by hooks/supervisor-guard.js branches (2) cumSev=error and
// (3) alertArmedAt / sentinel-hang. No side effects; receives pre-populated
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

// SSOT for the alert fallback recipe block — shown on every block reason so
// the user (or the supervisor subagent itself) can self-recover from an
// API-error retry loop by freezing the session deterministically.
function recipeBlock(stateSessionId, stateFilePath) {
  return [
    "Fallback (if the supervisor subagent invocation fails with an API error):",
    `  Run: bin/supervisor-write-alert --clear-l2-armed-at --set-l2-phase paused --session-id ${stateSessionId}`,
    "  This freezes the alert review for this session so the loop terminates. alert_phase=paused freezes the retry loop for this session.",
    `  State file: ${stateFilePath}`,
  ];
}

function formatCumSevErrorReason(findings, sessionId, workflowSessionId, supervisorPath, stateFilePath, stateSessionId) {
  const sk = stateSessionId == null ? sessionId : stateSessionId;
  const lines = [];
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
  lines.push("[EM Supervisor] Alert mode: cumulative_severity=error.");

  if (!Array.isArray(findings) || findings.length === 0) {
    lines.push("Categories: (none)");
    lines.push("Detail: (no findings recorded)");
    lines.push(`Session ID: ${sessionId}`);
    lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
    lines.push(`Effective state session ID: ${sk}`);
    lines.push(`Action: pass --session-id ${sk} to every bin/supervisor-write-alert call.`);
    for (const l of recipeBlock(sk, stateFilePath)) lines.push(l);
    lines.push(`Recommended action: follow agents/supervisor.md (${supervisorPath}) to resolve before continuing.`);
    return lines.join("\n");
  }

  const allCats = aggregateCategories(findings);
  lines.push(`Categories: ${allCats.length > 0 ? allCats.join(", ") : "(none)"}`);

  // Summarized findings: compute highest severity and last detail.
  const SRANK = { error: 2, warning: 1, notice: 0 };
  let highestSev = null;
  let lastDetail = null;
  for (const f of findings) {
    if (!f) continue;
    const s = f.severity;
    if (typeof s === "string" && SRANK[s] !== undefined) {
      if (highestSev === null || SRANK[s] > SRANK[highestSev]) highestSev = s;
    }
    if (f.detail != null) lastDetail = f.detail;
  }
  lines.push(`Findings: ${findings.length}, highest severity: ${highestSev !== null ? highestSev : "(none)"}. Full detail in state file (shown on request only).`);
  if (lastDetail === null) lines.push("Detail: (no detail)");

  lines.push(`Session ID: ${sessionId}`);
  lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
  lines.push(`Effective state session ID: ${sk}`);
  lines.push(`Action: pass --session-id ${sk} to every bin/supervisor-write-alert call.`);
  for (const l of recipeBlock(sk, stateFilePath)) lines.push(l);
  lines.push(`Recommended action: follow agents/supervisor.md (${supervisorPath}) to resolve before continuing.`);
  return lines.join("\n");
}

function formatL2ArmedReason(cause, sessionId, workflowSessionId, supervisorPath, stateFilePath, stateSessionId) {
  const sk = stateSessionId == null ? sessionId : stateSessionId;
  const lines = [];
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
  // #929: alert causes are non-numeric slugs — "sentinel-hang", "scheduled-review",
  // and off-proposal causes carry an "off proposal" token.
  const isC1 = cause === "sentinel-hang";
  const isC3 = typeof cause === "string" && cause.includes("off proposal");
  const causeLabel = isC1
    ? "stop_hook_active sentinel hang detected"
    : isC3
    ? `off-proposal detected (${cause})`
    : "scheduled review";

  lines.push(`[EM Supervisor] Alert mode review required (${causeLabel}).`);
  if (isC1) {
    lines.push("Trigger: stop_hook_active sentinel hang detected in the assistant transcript.");
  } else if (isC3) {
    const proposalType = cause.includes("worktree-off") ? "WORKTREE_OFF" : "WORKFLOW_OFF";
    lines.push(`Trigger: assistant output contained a ${proposalType} proposal sentinel (<<WORKFLOW_ENFORCE_${proposalType}>>).`);
    lines.push(`Verify: check whether this was a sanctioned use per skills/enforce-workflow-off/SKILL.md "Sanctioned-command false-block recovery". If so, the session can continue; if improvised bypass, recommend reverting.`);
  } else {
    lines.push("Trigger: scheduled alert review (alert_armed_at set).");
  }
  lines.push(`Action: invoke agents/supervisor.md (${supervisorPath}) as a subagent - run the JD checklist, provide first-aid guidance, then recommend /issue-create for root-cause fix.`);
  lines.push("To resume: clear the alert_armed_at field in the supervisor state file after the review is complete.");
  lines.push(`Clear: set alert.alert_armed_at = null in the state file.`);
  lines.push(`File: ${stateFilePath}`);
  const writerPath = path.resolve(__dirname, "supervisor-state-writer");
  lines.push(`Equivalent one-liner: node -e "require('${writerPath}').writeAlertState('${sk}', {alert_armed_at: null})"`);
  for (const l of recipeBlock(sk, stateFilePath)) lines.push(l);
  lines.push(`Session ID: ${sessionId}`);
  lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
  lines.push(`Effective state session ID: ${sk}`);
  lines.push(`Action: pass --session-id ${sk} to every bin/supervisor-write-alert call.`);
  return lines.join("\n");
}

function formatWorktreeOffProposalReason(sessionId, workflowSessionId, supervisorPath, stateFilePath, stateSessionId) {
  const sk = stateSessionId == null ? sessionId : stateSessionId;
  const lines = [];
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
  lines.push("[EM Supervisor] OFF proposal pre-detected.");
  lines.push(`Action: invoke agents/supervisor.md (${supervisorPath}) as a subagent to review the off-proposal.`);
  for (const l of recipeBlock(sk, stateFilePath)) lines.push(l);
  lines.push(`Session ID: ${sessionId}`);
  lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
  lines.push(`Effective state session ID: ${sk}`);
  lines.push(`Action: pass --session-id ${sk} to every bin/supervisor-write-alert call.`);
  return lines.join("\n");
}

// Pre-merge block reason: arms audit and redirects to supervisor-audit.md.
// cause is "warning-flush" or "scope-drift:pre-merge".
function formatPreMergeBlockReason(cause, sessionId, workflowSessionId, auditAgentPath, stateFilePath, stateSessionId) {
  const lines = [];
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
  lines.push("[EM Supervisor] Pre-merge audit required.");
  if (cause === "warning-flush") {
    lines.push("Reason: Active supervisor findings exist (warning severity or above).");
  } else if (cause === "scope-drift:pre-merge") {
    lines.push("Reason: Branch diff contains files not declared in detail.md (scope drift).");
  } else {
    lines.push(`Reason: ${cause}`);
  }
  lines.push("Action: Run agents/supervisor-audit.md as a subagent.");
  lines.push("Re-run the merge after the audit completes.");
  if (stateSessionId) lines.push(`Effective state session ID: ${stateSessionId}`);
  if (sessionId) lines.push(`Session ID: ${sessionId}`);
  if (workflowSessionId) lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
  return lines.join("\n");
}

// #2256 S5-e — pre-merge freshness backstop deny reason. The gate no longer
// arms an audit; it only re-checks that a terminal user_verification (TR5)
// audit exists, is fresh, and did not return BLOCK. `cause` is the caller's
// FRESHNESS_BACKSTOP_CAUSE label; `detailLine` names why the merge was denied
// (no TR5 run / stale inputs / BLOCK verdict / uncomputable freshness key) and,
// for a stale deny, which component moved.
function formatFreshnessBackstopReason(cause, detailLine, sessionId, workflowSessionId, stateSessionId) {
  const lines = [];
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
  lines.push("[EM Supervisor] Pre-merge freshness backstop denied the merge.");
  lines.push(`Cause: ${cause}`);
  if (detailLine) lines.push(`Reason: ${detailLine}`);
  lines.push("This gate arms no audit. The user_verification (TR5) audit must run and stay fresh before merge.");
  lines.push("Re-run the merge after a fresh, non-BLOCK TR5 verdict is recorded.");
  if (stateSessionId) lines.push(`Effective state session ID: ${stateSessionId}`);
  if (sessionId) lines.push(`Session ID: ${sessionId}`);
  if (workflowSessionId) lines.push(`Workflow session ID: ${wsidLabel(workflowSessionId)}`);
  return lines.join("\n");
}

// #720 — Audit reason formatters. Mirror the alert formatters' shape so the
// integrated formatter (format-integrated.js) can stack them side-by-side.

function formatL3StageBoundaryReason(stage, verdict, sessionId, stateFilePath) {
  const lines = [];
  lines.push(`[EM Supervisor] Audit mode review at CONFIRM_${stage}: ${verdict}.`);
  lines.push("Trigger: stage-boundary sentinel detected in assistant transcript.");
  lines.push(`Action: invoke agents/supervisor-audit.md as a subagent.`);
  if (sessionId) lines.push(`Session ID: ${sessionId}`);
  if (stateFilePath) lines.push(`State file: ${stateFilePath}`);
  return lines.join("\n");
}

function formatL3SeverityThresholdReason(cumSev, verdict, sessionId, stateFilePath) {
  const lines = [];
  lines.push(`[EM Supervisor] Audit mode review (cumulative_severity=${cumSev}): ${verdict}.`);
  lines.push("Trigger: cumulative severity reached audit threshold.");
  lines.push(`Action: invoke agents/supervisor-audit.md as a subagent.`);
  if (sessionId) lines.push(`Session ID: ${sessionId}`);
  if (stateFilePath) lines.push(`State file: ${stateFilePath}`);
  return lines.join("\n");
}

module.exports = { formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason, formatPreMergeBlockReason, formatFreshnessBackstopReason, formatL3StageBoundaryReason, formatL3SeverityThresholdReason };
