"use strict";

const fs = require("fs");

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
    ({ MARKER_RE_DQ, MARKER_RE_SQ } = require("../lib/sentinel-patterns"));
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
    } = require("../lib/sentinel-patterns"));
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
      if (item.type !== "tool_use" || item.name !== "Bash") continue;
      const text = (item.input && item.input.command) || "";
      if (!text) continue;
      cmdOrder++;
      if (WORKTREE_OFF_DQ.test(text) || WORKTREE_OFF_LL.test(text)) lastWorktreeOffIdx = cmdOrder;
      if (WORKTREE_ON_DQ.test(text) || WORKTREE_ON_LL.test(text)) lastWorktreeOnIdx = cmdOrder;
      if (WORKFLOW_OFF_DQ.test(text) || WORKFLOW_OFF_LL.test(text)) lastWorkflowOffIdx = cmdOrder;
      if (WORKFLOW_ON_DQ.test(text) || WORKFLOW_ON_LL.test(text)) lastWorkflowOnIdx = cmdOrder;
    }
  }
  const worktreeDetected = lastWorktreeOffIdx >= 0 && (lastWorktreeOnIdx < 0 || lastWorktreeOffIdx > lastWorktreeOnIdx);
  const workflowDetected = lastWorkflowOffIdx >= 0 && (lastWorkflowOnIdx < 0 || lastWorkflowOffIdx > lastWorkflowOnIdx);
  if (workflowDetected) return { detected: true, kind: "workflow-off" };
  if (worktreeDetected) return { detected: true, kind: "worktree-off" };
  return { detected: false, kind: null };
}

module.exports = { detectSentinelHang, detectAskUserQuestionTurn, parseTranscriptForAudit, detectOffProposal };
