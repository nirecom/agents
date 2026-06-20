#!/usr/bin/env node
// Stop hook: EM Supervisor Layer 2 block gate.
// Branch dispatch (evaluated in order):
//   (1) stop_hook_active=true                    -> exit 0 immediately
//   (C3) WORKTREE_OFF proposal pre-detected      -> increment-retry; if frozen exit 0; else block, exit 2
//   (2) cumulative_severity=error                -> increment-retry; if frozen exit 0; else block, exit 2
//   (3) detectSentinelHang || l2ArmedAt          -> increment-retry; if frozen exit 0; else block, exit 2
//   (4) cumulative_severity warning/notice       -> additionalContext advisory, exit 0
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

  let resolveSessionId, resolveWorkflowSessionId, isWorkflowOff, readState, getStatePath, incrementL2RetryCount;
  let formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ resolveWorkflowSessionId } = require("./lib/resolve-workflow-session-id"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState, getStatePath, incrementL2RetryCount } = require("./lib/supervisor-state-writer"));
    ({ formatCumSevErrorReason, formatL2ArmedReason, formatWorktreeOffProposalReason } = require("./lib/supervisor-report-format"));
  } catch (_) {
    process.exit(0);
  }

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

  let workflowSessionId = null;
  try {
    workflowSessionId = resolveWorkflowSessionId({});
  } catch (_) {
    workflowSessionId = null;
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

  // (5)
  process.exit(0);
}
