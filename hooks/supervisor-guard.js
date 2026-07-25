#!/usr/bin/env node
// Stop hook: EM Supervisor alert/audit block gate.
// Branch dispatch (evaluated in order):
//   (1) stop_hook_active=true                    -> exit 0 immediately
//   (audit-B) audit_phase=done                   -> surface audit verdict; if BLOCK -> exit 2; else fall through
//   (2) cumulative_severity=error                -> increment-retry; if frozen exit 0; else block, exit 2
//   (3) detectSentinelHang || alertArmedAt       -> increment-retry; if frozen exit 0; else block, exit 2
//   (4) legacy layer2 state + cumSev=warning/notice -> advisory additionalContext; exit 0 (new alert format skips)
//   (audit-A) CONFIRM_* sentinel or cumSev>=error -> arm audit (write pending); block with agent invocation msg; exit 2
//   (5) all-null                                 -> exit 0 silently
//
// AskUserQuestion gate (#903): when the last assistant turn ends with an
// AskUserQuestion tool_use, branches (2), (3) are suppressed — the
// user is already mid-dialog and the guard must not block on top.
// Fail-open on any error.
"use strict";

const fs = require("fs");
const path = require("path");
const { detectSentinelHang, detectAskUserQuestionTurn, parseTranscriptForAudit } = require('./supervisor-guard/detect');
const { TERMINAL_ALERT_PHASES } = require('./lib/supervisor-state-schema');

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

if (require.main === module) {
  let input = {};
  try {
    const raw = readStdin();
    if (!raw) process.exit(0);
    input = JSON.parse(raw);
  } catch (_) {
    process.exit(0);
  }

  // (1)
  if (input.stop_hook_active === true) process.exit(0);

  let resolveSessionId, isWorkflowOff, readState, getStatePath, incrementAlertRetryCount, writeAuditState, writeAlertState;
  let formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason;
  let arbitrate, formatIntegratedReason;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState, getStatePath, incrementAlertRetryCount, writeAuditState, writeAlertState } = require("./lib/supervisor-state-writer"));
    ({ formatCumSevErrorReason, formatL2ArmedReason } = require("./lib/supervisor-report-format"));
    ({ arbitrate } = require("./lib/supervisor-guard/arbitrate"));
    ({ formatIntegratedReason } = require("./lib/supervisor-guard/format-integrated"));
  } catch (_) {
    process.exit(0);
  }

  // Audit modules load separately so a bug in new files doesn't disable the alert guard.
  let collectAuditCandidatesFn = null;
  try {
    ({ collectAuditCandidates: collectAuditCandidatesFn } = require("./lib/supervisor-guard/collect-audit-triggers"));
  } catch (_) {}

  let sessionId = null;
  try {
    sessionId = resolveSessionId({
      sessionIdFromInput: input.session_id,
      transcriptPath: input.transcript_path,
    });
  } catch (_) {
    process.exit(0);
  }
  if (!sessionId) process.exit(0);
  // Defense-in-depth: sessionId flows into formatter recipe text as `node -e "...('${sessionId}', ...)"`.
  // resolveSessionId does not regex-validate, so reject anything that does not match the
  // canonical shape. Fail-open (exit 0) — the guard must never block on its own input parse.
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) process.exit(0);

  const effectiveSupervisorStateSessionId = sessionId;

  try {
    if (isWorkflowOff(sessionId)) process.exit(0);
  } catch (_) {
    process.exit(0);
  }

  // Quiet layer (#1607): a paused session suppresses every re-block branch
  // (cumSev=error / hang / alertArmedAt) and the audit-arm block. fail-open.
  try {
    const { isNextStepPaused } = require("./lib/session-markers");
    if (isNextStepPaused(sessionId)) process.exit(0);
  } catch (_) { /* fail-open */ }

  let state = null;
  try {
    state = readState(effectiveSupervisorStateSessionId);
  } catch (_) {
    state = null;
  }
  // No early exit on missing state — C1 transcript scan (path 3) runs regardless.

  const alertRaw = (state && state.alert) || {};
  // Compat: old state format wrote to state.layer2; fall back when alert has no meaningful signal.
  const alertHasData = alertRaw.cumulative_severity != null || alertRaw.alert_armed_at != null ||
    (Array.isArray(alertRaw.findings) && alertRaw.findings.length > 0);
  const alert = alertHasData ? alertRaw : ((state && state.layer2) || alertRaw);
  const isLegacyLayer2State = !alertHasData && !!(state && state.layer2);
  let alertArmedAt = alert.alert_armed_at == null ? null : alert.alert_armed_at;
  const cumSev = alert.cumulative_severity == null ? null : alert.cumulative_severity;
  const findings = Array.isArray(alert.findings) ? alert.findings : [];
  const alertPhase = alert.alert_phase === undefined ? null : alert.alert_phase;

  const agentsDir = process.env.AGENTS_CONFIG_DIR || "";
  const supervisorPath = agentsDir
    ? path.join(agentsDir, "agents", "supervisor.md")
    : "agents/supervisor.md";

  const askUserQuestionTurn = detectAskUserQuestionTurn(input.transcript_path || "");
  const hangDetected = detectSentinelHang(input.transcript_path || "");

  let stateFilePath = "";
  try {
    stateFilePath = getStatePath(effectiveSupervisorStateSessionId);
  } catch (_) {
    stateFilePath = "";
  }

  function tryIncrementFrozen() {
    try {
      const res = incrementAlertRetryCount(effectiveSupervisorStateSessionId);
      return res.frozen;
    } catch (_) {
      return false; // fail-open
    }
  }

  // Audit Phase B: surface completed verdict. Placed after detector vars and tryIncrementFrozen.
  const audit = (state && state.audit) || {};
  const auditPhase = audit.audit_phase === undefined ? null : audit.audit_phase;
  let pendingAuditWarnContext = null;
  if (auditPhase === "done" && writeAuditState) {
    const auditVerdict = audit.audit_verdict;
    const auditCause = audit.audit_cause || null;
    // Consume audit_phase regardless of verdict so Phase B doesn't re-fire next cycle.
    try { writeAuditState(effectiveSupervisorStateSessionId, { audit_phase: null }); } catch (_) {}
    const auditCandidate = {
      verdict: auditVerdict || "CONTINUE",
      reason: auditCause || `Audit mode strategic review: ${auditVerdict || "CONTINUE"} verdict.`,
    };
    // Clear alert_armed_at before alertWouldFire so a C2-only alert doesn't build a BLOCK
    // candidate that would beat the audit WARN in arbitration.
    // The in-memory clear propagates to branch (3) below; the file write is the mirror-clear fix.
    alertArmedAt = null;
    try { writeAlertState(effectiveSupervisorStateSessionId, { alert_armed_at: null }); } catch (_) {}
    // Build alert candidate only when an alert branch would also fire this cycle.
    let alertCandidate = null;
    const alertWouldFire = !askUserQuestionTurn &&
      !TERMINAL_ALERT_PHASES.has(alertPhase) &&
      // --- BEGIN temporary: alert_phase "frozen" legacy alias (#1166) ---
      alertPhase !== "frozen" &&
      // --- END temporary: alert_phase "frozen" legacy alias (#1166) ---
      (cumSev === "error" || hangDetected || alertArmedAt);
    if (alertWouldFire) {
      let alertReason;
      if (cumSev === "error") {
        alertReason = formatCumSevErrorReason(findings, sessionId, null, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
      } else {
        const cause = hangDetected ? "C1 sentinel hang" : "C2 scheduled-review";
        alertReason = formatL2ArmedReason(cause, sessionId, null, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
      }
      alertCandidate = { verdict: "BLOCK", reason: alertReason };
    }
    const arbitration = arbitrate ? arbitrate(alertCandidate, auditCandidate) : { decision: "allow", source: null, reason: "" };
    if (arbitration.decision === "block") {
      if (arbitration.source === "l2") {
        // alert-only block: apply alert freeze logic (matches branches 2/3 behavior).
        if (tryIncrementFrozen()) process.exit(0);
      }
      // audit or both source: never call tryIncrementFrozen (audit has its own freeze).
      const integratedReason = formatIntegratedReason
        ? formatIntegratedReason(arbitration, alertCandidate && alertCandidate.reason, auditCandidate.reason)
        : (arbitration.reason || auditCandidate.reason);
      try {
        process.stdout.write(JSON.stringify({ decision: "block", reason: integratedReason }) + "\n");
      } catch (_) {}
      process.exit(2);
    }
    if (arbitration.decision === "warn") {
      // Stash WARN and fall through — C3 BLOCK must take precedence (surfaced below at sub-step 2d).
      pendingAuditWarnContext = formatIntegratedReason
        ? formatIntegratedReason(arbitration, alertCandidate && alertCandidate.reason, auditCandidate.reason)
        : auditCandidate.reason;
    }
    // decision === "allow" or unrecognized: fall through to existing branches.
  }

  // (2)
  if (!askUserQuestionTurn && cumSev === "error" && !TERMINAL_ALERT_PHASES.has(alertPhase) &&
      // --- BEGIN temporary: alert_phase "frozen" legacy alias (#1166) ---
      alertPhase !== "frozen"
      // --- END temporary: alert_phase "frozen" legacy alias (#1166) ---
  ) {
    if (tryIncrementFrozen()) process.exit(0);
    const reason = formatCumSevErrorReason(findings, sessionId, null, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
    try {
      process.stdout.write(
        JSON.stringify({ decision: "block", reason, systemMessage: reason }) + "\n"
      );
    } catch (_) {}
    process.exit(2);
  }

  // (3)
  if (!askUserQuestionTurn && (hangDetected || alertArmedAt) && !TERMINAL_ALERT_PHASES.has(alertPhase) &&
      // --- BEGIN temporary: alert_phase "frozen" legacy alias (#1166) ---
      alertPhase !== "frozen"
      // --- END temporary: alert_phase "frozen" legacy alias (#1166) ---
  ) {
    if (tryIncrementFrozen()) process.exit(0);
    const cause = hangDetected ? "C1 sentinel hang" : "C2 scheduled-review";
    const reason = formatL2ArmedReason(cause, sessionId, null, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
    try {
      process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    } catch (_) {}
    process.exit(2);
  }

  // Audit WARN surface (sub-step 2d): after alert blocking branches, before advisory branch (4).
  // Precedence: audit BLOCK > C3 > alert BLOCK > audit WARN > alert advisory. Stash was set in Phase B above.
  if (pendingAuditWarnContext !== null) {
    try {
      process.stdout.write(JSON.stringify({ additionalContext: pendingAuditWarnContext }) + "\n");
    } catch (_) {}
    process.exit(0);
  }

  // (4) advisory for cumSev=warning or cumSev=notice — legacy layer2 backward-compat only.
  // New alert-format state (state.alert) skips this branch; only old layer2 state files trigger it.
  if (!askUserQuestionTurn && (cumSev === "warning" || cumSev === "notice") && !TERMINAL_ALERT_PHASES.has(alertPhase) &&
      // --- BEGIN temporary: alert_phase "frozen" legacy alias (#1166) ---
      alertPhase !== "frozen" &&
      // --- END temporary: alert_phase "frozen" legacy alias (#1166) ---
      isLegacyLayer2State) {
    const additionalContext = formatCumSevErrorReason(findings, sessionId, null, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
    try {
      process.stdout.write(JSON.stringify({ additionalContext }) + "\n");
    } catch (_) {}
    process.exit(0);
  }

  // (audit) Phase A: arm audit if a trigger fires and it hasn't already run for this cause.
  if (collectAuditCandidatesFn && writeAuditState && !askUserQuestionTurn) {
    const activePendingOrRunning = auditPhase === "pending" || auditPhase === "in_progress";
    if (!activePendingOrRunning && auditPhase !== "frozen" && alertPhase !== "closed") {
      const transcriptForAudit = parseTranscriptForAudit(input.transcript_path || "");
      let auditTrigger = { shouldArm: false, cause: null };
      try { auditTrigger = collectAuditCandidatesFn(transcriptForAudit, state); } catch (_) {}
      // Dedup: skip if audit already ran for this exact cause.
      const lastRunCause = audit.audit_cause || null;
      const lastRunAt = audit.audit_last_run_at || null;
      const alreadyRanForCause = lastRunAt && auditTrigger.cause && auditTrigger.cause === lastRunCause;
      if (auditTrigger.shouldArm && !alreadyRanForCause) {
        try {
          writeAuditState(effectiveSupervisorStateSessionId, {
            audit_phase: "pending",
            audit_armed_at: new Date().toISOString(),
            audit_cause: auditTrigger.cause || "",
            audit_retry_count: 0,
          });
        } catch (_) {}
        const auditAgentPath = agentsDir
          ? path.join(agentsDir, "agents", "supervisor-audit.md")
          : "agents/supervisor-audit.md";
        const auditArmReason = [
          "[EM Supervisor] Audit mode strategic review triggered.",
          `Trigger: ${auditTrigger.cause}`,
          `Session ID: ${sessionId}`,
          `Effective state session ID: ${effectiveSupervisorStateSessionId}`,
          `State file: ${stateFilePath}`,
          "",
          "Run the audit mode strategic review agent (Task tool or Agent tool):",
          `  Agent file: ${auditAgentPath}`,
          "",
          "The agent reads the state file and plan artifacts, then writes a verdict.",
          "After it completes, continue the workflow — the next Stop event surfaces the result.",
        ].join("\n");
        try {
          process.stdout.write(JSON.stringify({ decision: "block", reason: auditArmReason }) + "\n");
        } catch (_) {}
        process.exit(2);
      }
    }
  }

  // (5)
  process.exit(0);
}
