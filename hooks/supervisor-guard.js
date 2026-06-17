#!/usr/bin/env node
// Stop hook: EM Supervisor Layer 2 block gate.
// 5-way branch (evaluated in order):
//   (1) stop_hook_active=true       -> exit 0 immediately
//   (2) cumulative_severity=error   -> decision:block + systemMessage, exit 2
//   (3) detectSentinelHang || l2ArmedAt || C3-proposal -> decision:block (L2 review trigger), exit 2
//   (4) cumulative_severity warning/notice -> additionalContext advisory, exit 0
//   (5) all-null                    -> exit 0 silently
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

// Returns a C3 cause label if the last assistant turn's {type:"text"} content
// contains <<WORKFLOW_ENFORCE_WORKTREE_OFF or <<WORKFLOW_ENFORCE_WORKFLOW_OFF,
// or null if neither is found. WORKFLOW_OFF takes precedence (broader scope).
// Simple substring match — false-positive detection is delegated to the supervisor agent.
function detectWorktreeOffProposal(transcriptPath) {
  if (!transcriptPath) return null;
  let lines;
  try {
    lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
  } catch (_) {
    return null;
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
  if (!lastAssistant) return null;
  const content =
    lastAssistant.message &&
    Array.isArray(lastAssistant.message.content)
      ? lastAssistant.message.content
      : [];
  let foundWorktreeOff = false;
  let foundWorkflowOff = false;
  for (const item of content) {
    if (item.type !== "text" || typeof item.text !== "string") continue;
    if (item.text.includes("<<WORKFLOW_ENFORCE_WORKFLOW_OFF")) foundWorkflowOff = true;
    if (item.text.includes("<<WORKFLOW_ENFORCE_WORKTREE_OFF")) foundWorktreeOff = true;
  }
  if (foundWorkflowOff) return "C3 workflow-off proposal";
  if (foundWorktreeOff) return "C3 worktree-off proposal";
  return null;
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

  let resolveSessionId, resolveWorkflowSessionId, isWorkflowOff, readState, getStatePath;
  let readStateOrInit, ensureLayer2Scheduled, writeAtomic, validate;
  let formatCumSevErrorReason, formatL2ArmedReason;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ resolveWorkflowSessionId } = require("./lib/resolve-workflow-session-id"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState, getStatePath, readStateOrInit, ensureLayer2Scheduled, writeAtomic } = require("./lib/supervisor-state-writer"));
    ({ formatCumSevErrorReason, formatL2ArmedReason } = require("./lib/supervisor-report-format"));
    ({ validate } = require("./lib/supervisor-state-schema"));
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

  let workflowSessionId = null;
  try {
    workflowSessionId = resolveWorkflowSessionId({});
  } catch (_) {
    workflowSessionId = null;
  }

  try {
    if (isWorkflowOff(sessionId)) process.exit(0);
  } catch (_) {
    process.exit(0);
  }

  let state = null;
  try {
    state = readState(sessionId);
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

  // (2)
  if (cumSev === "error") {
    const reason = formatCumSevErrorReason(findings, sessionId, workflowSessionId, supervisorPath);
    try {
      process.stdout.write(
        JSON.stringify({ decision: "block", reason, systemMessage: reason }) + "\n"
      );
    } catch (_) {}
    process.exit(2);
  }

  // C3: detect off-proposal sentinel; arm l2_armed_at via ensureLayer2Scheduled
  let c3Cause = null;
  let c3Armed = false;
  try {
    const c3Detected = detectWorktreeOffProposal(input.transcript_path || "");
    if (c3Detected && l2Phase !== "done" && l2Phase !== "frozen") {
      const c3State = readStateOrInit(sessionId);
      const prevArmedAt = c3State.layer2 && c3State.layer2.l2_armed_at;
      ensureLayer2Scheduled(c3State, sessionId);
      if (c3State.layer2 && c3State.layer2.l2_armed_at !== prevArmedAt) {
        c3State.layer2.l2_cause = c3Detected;
        const vr = validate(c3State);
        if (vr.ok) {
          writeAtomic(getStatePath(sessionId), c3State);
          c3Cause = c3Detected;
          c3Armed = true;
        }
      }
    }
  } catch (_) {}

  // (3)
  const hangDetected = detectSentinelHang(input.transcript_path || "");
  if ((hangDetected || l2ArmedAt || c3Armed) && l2Phase !== "done" && l2Phase !== "frozen") {
    const cause = hangDetected
      ? "C1 sentinel hang"
      : c3Armed ? c3Cause : (layer2.l2_cause || "C2 scheduled-review");
    let stateFilePath = "";
    try {
      stateFilePath = getStatePath(sessionId);
    } catch (_) {
      stateFilePath = "";
    }
    const reason = formatL2ArmedReason(cause, sessionId, workflowSessionId, supervisorPath, stateFilePath);
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
