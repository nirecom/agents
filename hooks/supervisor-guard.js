#!/usr/bin/env node
// Stop hook: EM Supervisor alert/audit block gate.
// Branch dispatch (evaluated in order):
//   (1) stop_hook_active=true                    -> exit 0 immediately
//   (audit-B) audit_phase=done                   -> surface audit verdict; if BLOCK -> exit 2; else fall through
//   (C3) OFF proposal pre-detected               -> increment-retry; if frozen exit 0; else block, exit 2
//   (2) cumulative_severity=error                -> increment-retry; if frozen exit 0; else block, exit 2
//   (3) detectSentinelHang || alertArmedAt       -> increment-retry; if frozen exit 0; else block, exit 2
//   (4) cumulative_severity warning/notice       -> additionalContext advisory, exit 0
//   (audit-A) CONFIRM_* sentinel or cumSev>=error -> arm audit (write pending); block with agent invocation msg; exit 2
//   (5) all-null                                 -> exit 0 silently
//
// AskUserQuestion gate (#903): when the last assistant turn ends with an
// AskUserQuestion tool_use, branches (C3), (2), (3) are suppressed — the
// user is already mid-dialog and the guard must not block on top.
// Fail-open on any error.
"use strict";

const fs = require("fs");
const path = require("path");

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

// Returns true if the last assistant turn's content array ends with a MARK_STEP
// Bash tool_use and no tool_use follows it in the same array (sentinel hang).
// CONFIRM_* Bash calls are exempt (they pause for approval, not a hang).
// Uses MARKER_RE_DQ + MARKER_RE_SQ from sentinel-patterns.js (SSOT); fails open if unavailable.
function detectSentinelHang(transcriptPath) {
  if (!transcriptPath) return false;
  let lines;
  try {
    lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
  } catch (_) {
    return false;
  }
  let MARKER_RE_DQ, MARKER_RE_SQ;
  try {
    ({ MARKER_RE_DQ, MARKER_RE_SQ } = require("./lib/sentinel-patterns"));
  } catch (_) {
    return false;
  }
  const SENTINEL_HANG_EXEMPT_STEPS = new Set(["final_report", "pre_final_report_gate"]);
  const tail = lines.slice(-100);
  let lastAssistant = null;
  for (const line of tail) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      if (entry.type === "assistant") lastAssistant = entry;
    } catch (_) {}
  }
  if (!lastAssistant) return false;
  const content =
    lastAssistant.message &&
    Array.isArray(lastAssistant.message.content)
      ? lastAssistant.message.content
      : [];
  let markStepIdx = -1;
  for (let i = 0; i < content.length; i++) {
    const item = content[i];
    if (item.type === "tool_use" && item.name === "Bash") {
      const cmd = (item.input && item.input.command) || "";
      const m = MARKER_RE_DQ.exec(cmd) || MARKER_RE_SQ.exec(cmd);
      if (m) {
        if (!SENTINEL_HANG_EXEMPT_STEPS.has(m[1])) markStepIdx = i;
      }
    }
  }
  if (markStepIdx < 0) return false;
  for (let i = markStepIdx + 1; i < content.length; i++) {
    if (content[i].type === "tool_use") return false;
  }
  return true;
}

// Returns true if the last assistant turn's content array's LAST tool_use is
// an AskUserQuestion. When true, the user is mid-dialog and alert mode block
// branches must be suppressed (#903).
function detectAskUserQuestionTurn(transcriptPath) {
  if (!transcriptPath) return false;
  let lines;
  try {
    lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
  } catch (_) {
    return false;
  }
  const tail = lines.slice(-100);
  let lastAssistant = null;
  for (const line of tail) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      if (entry.type === "assistant") lastAssistant = entry;
    } catch (_) {}
  }
  if (!lastAssistant) return false;
  const content =
    lastAssistant.message &&
    Array.isArray(lastAssistant.message.content)
      ? lastAssistant.message.content
      : [];
  let lastToolUse = null;
  for (const item of content) {
    if (item && item.type === "tool_use") lastToolUse = item;
  }
  if (!lastToolUse) return false;
  return lastToolUse.name === "AskUserQuestion";
}

// Parses the JSONL transcript into [{role,content}] format for collectAuditCandidates.
function parseTranscriptForAudit(transcriptPath) {
  if (!transcriptPath) return [];
  let lines;
  try { lines = fs.readFileSync(transcriptPath, "utf8").split("\n"); } catch (_) { return []; }
  const result = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      if (entry.type === "assistant" && entry.message) {
        result.push({ role: "assistant", content: entry.message.content || "" });
      }
    } catch (_) {}
  }
  return result;
}

// Returns { detected: boolean, kind: string|null } if an OFF sentinel was proposed
// (Bash tool_use) in any assistant turn within the FULL transcript, and no later ON
// sentinel followed it. Checks both WORKTREE_OFF and WORKFLOW_OFF sentinels.
// Scope alignment (#912 Orthogonality §4): scans the whole transcript to match
// stop-enforce-worktree-on-warn.js — both siblings detect the same OFF/ON pair
// and must agree on visibility.
function detectOffProposal(transcriptPath) {
  if (!transcriptPath) return { detected: false, kind: null };
  let lines;
  try {
    lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
  } catch (_) {
    return { detected: false, kind: null };
  }
  let WORKTREE_OFF_DQ, WORKTREE_OFF_LL, WORKTREE_ON_DQ, WORKTREE_ON_LL;
  let WORKFLOW_OFF_DQ, WORKFLOW_OFF_LL, WORKFLOW_ON_DQ, WORKFLOW_ON_LL;
  try {
    ({
      ENFORCE_WORKTREE_OFF_RE_DQ: WORKTREE_OFF_DQ,
      ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE: WORKTREE_OFF_LL,
      ENFORCE_WORKTREE_ON_RE_DQ: WORKTREE_ON_DQ,
      ENFORCE_WORKTREE_ON_LOOKSLIKE_RE: WORKTREE_ON_LL,
      ENFORCE_WORKFLOW_OFF_RE_DQ: WORKFLOW_OFF_DQ,
      ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE: WORKFLOW_OFF_LL,
      ENFORCE_WORKFLOW_ON_RE_DQ: WORKFLOW_ON_DQ,
      ENFORCE_WORKFLOW_ON_LOOKSLIKE_RE: WORKFLOW_ON_LL,
    } = require("./lib/sentinel-patterns"));
  } catch (_) {
    return { detected: false, kind: null };
  }
  let cmdOrder = 0;
  let lastWorktreeOffIdx = -1;
  let lastWorktreeOnIdx = -1;
  let lastWorkflowOffIdx = -1;
  let lastWorkflowOnIdx = -1;
  for (const line of lines) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch (_) {
      continue;
    }
    if (entry.type !== "assistant") continue;
    const content =
      entry.message && Array.isArray(entry.message.content)
        ? entry.message.content
        : [];
    for (const item of content) {
      if (!item) continue;
      let text = "";
      let isTextItem = false;
      if (item.type === "tool_use" && item.name === "Bash") {
        text = (item.input && item.input.command) || "";
      } else if (item.type === "text") {
        text = item.text || "";
        isTextItem = true;
      } else {
        continue;
      }
      if (!text) continue;
      cmdOrder++;
      if (isTextItem) {
        // Text content: use broad substring match (sentinel may not be in echo "..." form).
        if (text.includes("WORKFLOW_ENFORCE_WORKTREE_OFF")) lastWorktreeOffIdx = cmdOrder;
        if (text.includes("WORKFLOW_ENFORCE_WORKTREE_ON")) lastWorktreeOnIdx = cmdOrder;
        if (text.includes("WORKFLOW_ENFORCE_WORKFLOW_OFF")) lastWorkflowOffIdx = cmdOrder;
        if (text.includes("WORKFLOW_ENFORCE_WORKFLOW_ON")) lastWorkflowOnIdx = cmdOrder;
      } else {
        if (WORKTREE_OFF_DQ.test(text) || WORKTREE_OFF_LL.test(text)) lastWorktreeOffIdx = cmdOrder;
        if (WORKTREE_ON_DQ.test(text) || WORKTREE_ON_LL.test(text)) lastWorktreeOnIdx = cmdOrder;
        if (WORKFLOW_OFF_DQ.test(text) || WORKFLOW_OFF_LL.test(text)) lastWorkflowOffIdx = cmdOrder;
        if (WORKFLOW_ON_DQ.test(text) || WORKFLOW_ON_LL.test(text)) lastWorkflowOnIdx = cmdOrder;
      }
    }
  }
  const worktreeDetected = lastWorktreeOffIdx >= 0 && (lastWorktreeOnIdx < 0 || lastWorktreeOffIdx > lastWorktreeOnIdx);
  const workflowDetected = lastWorkflowOffIdx >= 0 && (lastWorkflowOnIdx < 0 || lastWorkflowOffIdx > lastWorkflowOnIdx);
  if (workflowDetected) return { detected: true, kind: "workflow-off" };
  if (worktreeDetected) return { detected: true, kind: "worktree-off" };
  return { detected: false, kind: null };
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

  let resolveSessionId, resolveWorkflowSessionId, isWorkflowOff, readState, getStatePath, incrementAlertRetryCount, writeAuditState, writeAlertState;
  let formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason;
  let arbitrate, formatIntegratedReason;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ resolveWorkflowSessionId } = require("./lib/resolve-workflow-session-id"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState, getStatePath, incrementAlertRetryCount, writeAuditState, writeAlertState } = require("./lib/supervisor-state-writer"));
    ({ formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason } = require("./lib/supervisor-report-format"));
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

  // wsid resolution for the audit-arm three-ID stanza and effective-state fallback.
  // Priority: WORKFLOW_SESSION_ID env var (set by /worktree-start, propagates
  // cleanly into hook subprocesses) > CWD WORKTREE_NOTES.md / plans-dir scan
  // (defensive fallback when env propagation breaks — Anthropic bug #27987).
  let workflowSessionId = null;
  const envWsid = process.env.WORKFLOW_SESSION_ID;
  if (envWsid && /^[A-Za-z0-9_-]+$/.test(envWsid)) {
    workflowSessionId = envWsid;
  } else {
    try {
      workflowSessionId = resolveWorkflowSessionId({});
    } catch (_) {
      workflowSessionId = null;
    }
  }

  let effectiveSupervisorStateSessionId = sessionId;
  try {
    // Resolve effective state-file session ID: prefer the CC UUID if its state
    // file is non-null; fall back to workflowSessionId when available, different,
    // and its state file is non-null. Uses readState() (not existsSync) so that
    // a zero-length or corrupt CC-UUID file triggers fallback correctly.
    if (
      workflowSessionId &&
      workflowSessionId !== sessionId &&
      /^[A-Za-z0-9_-]+$/.test(workflowSessionId)
    ) {
      const primaryState = readState(sessionId);
      if (primaryState === null) {
        const fallbackState = readState(workflowSessionId);
        if (fallbackState !== null) {
          effectiveSupervisorStateSessionId = workflowSessionId;
        }
      } else {
        // Also fall through when primaryState exists but is unarmed and
        // the wsid state is armed (e.g. report-writer wrote to wsid file).
        const primaryArmed =
          primaryState.alert && primaryState.alert.alert_armed_at;
        if (primaryArmed == null) {
          const fallbackState = readState(workflowSessionId);
          if (
            fallbackState &&
            fallbackState.alert &&
            fallbackState.alert.alert_armed_at != null
          ) {
            effectiveSupervisorStateSessionId = workflowSessionId;
          }
        }
      }
    }
  } catch (_) {
    effectiveSupervisorStateSessionId = sessionId; // fail-open
  }

  try {
    if (isWorkflowOff(sessionId)) process.exit(0);
  } catch (_) {
    process.exit(0);
  }

  let state = null;
  try {
    state = readState(effectiveSupervisorStateSessionId);
  } catch (_) {
    state = null;
  }
  // No early exit on missing state — C1 transcript scan (path 3) runs regardless.

  const alert = (state && state.alert) || {};
  const alertArmedAt = alert.alert_armed_at == null ? null : alert.alert_armed_at;
  const cumSev = alert.cumulative_severity == null ? null : alert.cumulative_severity;
  const findings = Array.isArray(alert.findings) ? alert.findings : [];
  const alertPhase = alert.alert_phase === undefined ? null : alert.alert_phase;

  const agentsDir = process.env.AGENTS_CONFIG_DIR || "";
  const supervisorPath = agentsDir
    ? path.join(agentsDir, "agents", "supervisor.md")
    : "agents/supervisor.md";

  const askUserQuestionTurn = detectAskUserQuestionTurn(input.transcript_path || "");
  const offProposal = detectOffProposal(input.transcript_path || "");
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
    // Mirror the clear so the other identity's store doesn't retain a stale audit_phase=done.
    const auditPhaseClearMirrorSid =
      effectiveSupervisorStateSessionId === sessionId ? workflowSessionId : sessionId;
    if (auditPhaseClearMirrorSid && auditPhaseClearMirrorSid !== effectiveSupervisorStateSessionId) {
      try { writeAuditState(auditPhaseClearMirrorSid, { audit_phase: null }); } catch (_) {}
    }
    const auditCandidate = {
      verdict: auditVerdict || "CONTINUE",
      reason: auditCause || `Audit mode strategic review: ${auditVerdict || "CONTINUE"} verdict.`,
    };
    // Build alert candidate only when an alert branch would also fire this cycle.
    let alertCandidate = null;
    const alertWouldFire = !askUserQuestionTurn &&
      alertPhase !== "done" && alertPhase !== "frozen" &&
      (cumSev === "error" || hangDetected || alertArmedAt);
    if (alertWouldFire) {
      let alertReason;
      if (cumSev === "error") {
        alertReason = formatCumSevErrorReason(findings, sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
      } else {
        const cause = hangDetected ? "C1 sentinel hang" : "C2 scheduled-review";
        alertReason = formatL2ArmedReason(cause, sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
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

  // (C3) OFF proposal pre-detection
  if (!askUserQuestionTurn && offProposal.detected) {
    if (tryIncrementFrozen()) process.exit(0);
    const causeLabel = offProposal.kind === "workflow-off"
      ? "C3 workflow-off proposal"
      : "C3 worktree-off proposal";
    try {
      writeAlertState(effectiveSupervisorStateSessionId, { alert_cause: causeLabel, alert_phase: "pending" });
    } catch (_) {}
    const reason = formatWorktreeOffProposalReason(sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
    try {
      process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    } catch (_) {}
    process.exit(2);
  }

  // (2)
  if (!askUserQuestionTurn && cumSev === "error" && alertPhase !== "done" && alertPhase !== "frozen") {
    if (tryIncrementFrozen()) process.exit(0);
    const reason = formatCumSevErrorReason(findings, sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
    try {
      process.stdout.write(
        JSON.stringify({ decision: "block", reason, systemMessage: reason }) + "\n"
      );
    } catch (_) {}
    process.exit(2);
  }

  // (3)
  if (!askUserQuestionTurn && (hangDetected || alertArmedAt) && alertPhase !== "done" && alertPhase !== "frozen") {
    if (tryIncrementFrozen()) process.exit(0);
    const cause = hangDetected ? "C1 sentinel hang" : "C2 scheduled-review";
    const reason = formatL2ArmedReason(cause, sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
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

  // (4)
  if (cumSev === "warning" || cumSev === "notice") {
    const advisory =
      `[EM Supervisor] alert mode advisory (${cumSev}): ${findings.length} finding(s). ` +
      `Review agents/supervisor.md for the full checklist and resolution path.`;
    try {
      process.stdout.write(JSON.stringify({ additionalContext: advisory }) + "\n");
    } catch (_) {}
    process.exit(0);
  }

  // (audit) Phase A: arm audit if a trigger fires and it hasn't already run for this cause.
  if (collectAuditCandidatesFn && writeAuditState && !askUserQuestionTurn) {
    const activePendingOrRunning = auditPhase === "pending" || auditPhase === "in_progress";
    if (!activePendingOrRunning && auditPhase !== "frozen") {
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
          `Workflow session ID: ${workflowSessionId == null ? "UNAVAILABLE" : workflowSessionId}`,
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
