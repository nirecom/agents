#!/usr/bin/env node
// Stop hook: EM Supervisor Layer 2/3 block gate.
// Branch dispatch (evaluated in order):
//   (1) stop_hook_active=true                    -> exit 0 immediately
//   (L3-B) l3_phase=done                         -> surface L3 verdict; if BLOCK -> exit 2; else fall through
//   (C3) WORKTREE_OFF proposal pre-detected      -> increment-retry; if frozen exit 0; else block, exit 2
//   (2) cumulative_severity=error                -> increment-retry; if frozen exit 0; else block, exit 2
//   (3) detectSentinelHang || l2ArmedAt          -> increment-retry; if frozen exit 0; else block, exit 2
//   (4) cumulative_severity warning/notice       -> additionalContext advisory, exit 0
//   (L3-A) CONFIRM_* sentinel or cumSev>=error   -> arm L3 (write pending); block with agent invocation msg; exit 2
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
// an AskUserQuestion. When true, the user is mid-dialog and Layer 2 block
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

// Parses the JSONL transcript into [{role,content}] format for collectL3Candidates.
function parseTranscriptForL3(transcriptPath) {
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

// Returns true if a WORKTREE_OFF sentinel was proposed (Bash tool_use) in any
// assistant turn within the FULL transcript, and no later WORKTREE_ON sentinel
// followed it. This is the C3 pre-detection used to fire a Layer 2 review on
// the proposal itself before it can be approved.
// Scope alignment (#912 Orthogonality §4): scans the whole transcript to match
// stop-enforce-worktree-on-warn.js — both siblings detect the same OFF/ON pair
// and must agree on visibility, so a stale OFF outside the 100-line tail does
// not cause one to fire while the other stays silent.
function detectWorktreeOffProposal(transcriptPath) {
  if (!transcriptPath) return false;
  let lines;
  try {
    lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
  } catch (_) {
    return false;
  }
  let OFF_DQ, OFF_LL, ON_DQ, ON_LL;
  try {
    ({
      ENFORCE_WORKTREE_OFF_RE_DQ: OFF_DQ,
      ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE: OFF_LL,
      ENFORCE_WORKTREE_ON_RE_DQ: ON_DQ,
      ENFORCE_WORKTREE_ON_LOOKSLIKE_RE: ON_LL,
    } = require("./lib/sentinel-patterns"));
  } catch (_) {
    return false;
  }
  let cmdOrder = 0;
  let lastOffIdx = -1;
  let lastOnIdx = -1;
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
      if (!item || item.type !== "tool_use" || item.name !== "Bash") continue;
      const cmd = (item.input && item.input.command) || "";
      cmdOrder++;
      if (OFF_DQ.test(cmd) || OFF_LL.test(cmd)) lastOffIdx = cmdOrder;
      if (ON_DQ.test(cmd) || ON_LL.test(cmd)) lastOnIdx = cmdOrder;
    }
  }
  return lastOffIdx >= 0 && (lastOnIdx < 0 || lastOffIdx > lastOnIdx);
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

  let resolveSessionId, resolveWorkflowSessionId, isWorkflowOff, readState, getStatePath, incrementL2RetryCount, writeLayer3State;
  let formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason;
  let arbitrate, formatIntegratedReason;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ resolveWorkflowSessionId } = require("./lib/resolve-workflow-session-id"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState, getStatePath, incrementL2RetryCount, writeLayer3State } = require("./lib/supervisor-state-writer"));
    ({ formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason } = require("./lib/supervisor-report-format"));
    ({ arbitrate } = require("./lib/supervisor-guard/arbitrate"));
    ({ formatIntegratedReason } = require("./lib/supervisor-guard/format-integrated"));
  } catch (_) {
    process.exit(0);
  }

  // L3 modules load separately so a bug in new files doesn't disable the L2 guard.
  let collectL3CandidatesFn = null;
  try {
    ({ collectL3Candidates: collectL3CandidatesFn } = require("./lib/supervisor-guard/collect-l3"));
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

  // wsid resolution for the L3-arm three-ID stanza and effective-state fallback.
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
          primaryState.layer2 && primaryState.layer2.l2_armed_at;
        if (primaryArmed == null) {
          const fallbackState = readState(workflowSessionId);
          if (
            fallbackState &&
            fallbackState.layer2 &&
            fallbackState.layer2.l2_armed_at != null
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

  const layer2 = (state && state.layer2) || {};
  const l2ArmedAt = layer2.l2_armed_at == null ? null : layer2.l2_armed_at;
  const cumSev = layer2.cumulative_severity == null ? null : layer2.cumulative_severity;
  const findings = Array.isArray(layer2.findings) ? layer2.findings : [];
  const l2Phase = layer2.l2_phase === undefined ? null : layer2.l2_phase;

  const agentsDir = process.env.AGENTS_CONFIG_DIR || "";
  const supervisorPath = agentsDir
    ? path.join(agentsDir, "agents", "supervisor.md")
    : "agents/supervisor.md";

  const askUserQuestionTurn = detectAskUserQuestionTurn(input.transcript_path || "");
  const worktreeOffProposal = detectWorktreeOffProposal(input.transcript_path || "");
  const hangDetected = detectSentinelHang(input.transcript_path || "");

  let stateFilePath = "";
  try {
    stateFilePath = getStatePath(effectiveSupervisorStateSessionId);
  } catch (_) {
    stateFilePath = "";
  }

  function tryIncrementFrozen() {
    try {
      const res = incrementL2RetryCount(effectiveSupervisorStateSessionId);
      return res.frozen;
    } catch (_) {
      return false; // fail-open
    }
  }

  // L3 Phase B: surface completed verdict. Placed after detector vars and tryIncrementFrozen.
  const layer3 = (state && state.layer3) || {};
  const l3Phase = layer3.l3_phase === undefined ? null : layer3.l3_phase;
  let pendingL3WarnContext = null;
  if (l3Phase === "done" && writeLayer3State) {
    const l3Verdict = layer3.l3_verdict;
    const l3Cause = layer3.l3_cause || null;
    // Consume l3_phase regardless of verdict so Phase B doesn't re-fire next cycle.
    try { writeLayer3State(effectiveSupervisorStateSessionId, { l3_phase: null }); } catch (_) {}
    // Mirror the clear so the other identity's store doesn't retain a stale l3_phase=done.
    const l3PhaseClearMirrorSid =
      effectiveSupervisorStateSessionId === sessionId ? workflowSessionId : sessionId;
    if (l3PhaseClearMirrorSid && l3PhaseClearMirrorSid !== effectiveSupervisorStateSessionId) {
      try { writeLayer3State(l3PhaseClearMirrorSid, { l3_phase: null }); } catch (_) {}
    }
    const l3Candidate = {
      verdict: l3Verdict || "CONTINUE",
      reason: l3Cause || `Layer 3 strategic review: ${l3Verdict || "CONTINUE"} verdict.`,
    };
    // Build L2 candidate only when an L2 branch would also fire this cycle.
    let l2Candidate = null;
    const l2WouldFire = !askUserQuestionTurn &&
      l2Phase !== "done" && l2Phase !== "frozen" &&
      (cumSev === "error" || hangDetected || l2ArmedAt);
    if (l2WouldFire) {
      let l2Reason;
      if (cumSev === "error") {
        l2Reason = formatCumSevErrorReason(findings, sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
      } else {
        const cause = hangDetected ? "C1 sentinel hang" : "C2 scheduled-review";
        l2Reason = formatL2ArmedReason(cause, sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
      }
      l2Candidate = { verdict: "BLOCK", reason: l2Reason };
    }
    const arbitration = arbitrate ? arbitrate(l2Candidate, l3Candidate) : { decision: "allow", source: null, reason: "" };
    if (arbitration.decision === "block") {
      if (arbitration.source === "l2") {
        // L2-only block: apply L2 freeze logic (matches branches 2/3 behavior).
        if (tryIncrementFrozen()) process.exit(0);
      }
      // l3 or both source: never call tryIncrementFrozen (L3 has its own freeze).
      const integratedReason = formatIntegratedReason
        ? formatIntegratedReason(arbitration, l2Candidate && l2Candidate.reason, l3Candidate.reason)
        : (arbitration.reason || l3Candidate.reason);
      try {
        process.stdout.write(JSON.stringify({ decision: "block", reason: integratedReason }) + "\n");
      } catch (_) {}
      process.exit(2);
    }
    if (arbitration.decision === "warn") {
      // Stash WARN and fall through — C3 BLOCK must take precedence (surfaced below at sub-step 2d).
      pendingL3WarnContext = formatIntegratedReason
        ? formatIntegratedReason(arbitration, l2Candidate && l2Candidate.reason, l3Candidate.reason)
        : l3Candidate.reason;
    }
    // decision === "allow" or unrecognized: fall through to existing branches.
  }

  // (C3) WORKTREE_OFF proposal pre-detection
  if (!askUserQuestionTurn && worktreeOffProposal) {
    if (tryIncrementFrozen()) process.exit(0);
    const reason = formatWorktreeOffProposalReason(sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
    try {
      process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    } catch (_) {}
    process.exit(2);
  }

  // (2)
  if (!askUserQuestionTurn && cumSev === "error" && l2Phase !== "done" && l2Phase !== "frozen") {
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
  if (!askUserQuestionTurn && (hangDetected || l2ArmedAt) && l2Phase !== "done" && l2Phase !== "frozen") {
    if (tryIncrementFrozen()) process.exit(0);
    const cause = hangDetected ? "C1 sentinel hang" : "C2 scheduled-review";
    const reason = formatL2ArmedReason(cause, sessionId, workflowSessionId, supervisorPath, stateFilePath, effectiveSupervisorStateSessionId);
    try {
      process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    } catch (_) {}
    process.exit(2);
  }

  // L3 WARN surface (sub-step 2d): after L2 blocking branches, before advisory branch (4).
  // Precedence: L3 BLOCK > C3 > L2 BLOCK > L3 WARN > L2 advisory. Stash was set in Phase B above.
  if (pendingL3WarnContext !== null) {
    try {
      process.stdout.write(JSON.stringify({ additionalContext: pendingL3WarnContext }) + "\n");
    } catch (_) {}
    process.exit(0);
  }

  // (4)
  if (cumSev === "warning" || cumSev === "notice") {
    const advisory =
      `[EM Supervisor] Layer 2 advisory (${cumSev}): ${findings.length} finding(s). ` +
      `Review agents/supervisor.md for the full checklist and resolution path.`;
    try {
      process.stdout.write(JSON.stringify({ additionalContext: advisory }) + "\n");
    } catch (_) {}
    process.exit(0);
  }

  // (L3) Phase A: arm L3 if a trigger fires and it hasn't already run for this cause.
  if (collectL3CandidatesFn && writeLayer3State && !askUserQuestionTurn) {
    const activePendingOrRunning = l3Phase === "pending" || l3Phase === "in_progress";
    if (!activePendingOrRunning && l3Phase !== "frozen") {
      const transcriptForL3 = parseTranscriptForL3(input.transcript_path || "");
      let l3Trigger = { shouldArm: false, cause: null };
      try { l3Trigger = collectL3CandidatesFn(transcriptForL3, state); } catch (_) {}
      // Dedup: skip if L3 already ran for this exact cause.
      const lastRunCause = layer3.l3_cause || null;
      const lastRunAt = layer3.l3_last_run_at || null;
      const alreadyRanForCause = lastRunAt && l3Trigger.cause && l3Trigger.cause === lastRunCause;
      if (l3Trigger.shouldArm && !alreadyRanForCause) {
        try {
          writeLayer3State(effectiveSupervisorStateSessionId, {
            l3_phase: "pending",
            l3_armed_at: new Date().toISOString(),
            l3_cause: l3Trigger.cause || "",
            l3_retry_count: 0,
          });
        } catch (_) {}
        const l3AgentPath = agentsDir
          ? path.join(agentsDir, "agents", "supervisor-layer3.md")
          : "agents/supervisor-layer3.md";
        const l3ArmReason = [
          "[EM Supervisor] Layer 3 strategic review triggered.",
          `Trigger: ${l3Trigger.cause}`,
          `Session ID: ${sessionId}`,
          `Workflow session ID: ${workflowSessionId == null ? "UNAVAILABLE" : workflowSessionId}`,
          `Effective state session ID: ${effectiveSupervisorStateSessionId}`,
          `State file: ${stateFilePath}`,
          "",
          "Run the Layer 3 strategic review agent (Task tool or Agent tool):",
          `  Agent file: ${l3AgentPath}`,
          "",
          "The agent reads the state file and plan artifacts, then writes a verdict.",
          "After it completes, continue the workflow — the next Stop event surfaces the result.",
        ].join("\n");
        try {
          process.stdout.write(JSON.stringify({ decision: "block", reason: l3ArmReason }) + "\n");
        } catch (_) {}
        process.exit(2);
      }
    }
  }

  // (5)
  process.exit(0);
}
