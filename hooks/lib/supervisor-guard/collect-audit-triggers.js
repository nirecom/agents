"use strict";

// #720 — Audit mode trigger collector.
// Pure function: examines transcript + supervisor-state and decides whether
// to arm an audit mode strategic review. Two triggers:
//   (a) stage boundary: a WORKFLOW_CONFIRM_{INTENT|OUTLINE|DETAIL} sentinel
//       appears in the most recent assistant turn(s).
//   (b) severity threshold: state.alert.cumulative_severity ranks >=
//       AUDIT_SEVERITY_THRESHOLD.
// Anti-thrash: when audit_phase is pending/in_progress/frozen, never re-arm.

const { AUDIT_SEVERITY_THRESHOLD, SEVERITY_RANK } = require("../supervisor-state-schema");

const CONFIRM_RE = /<<WORKFLOW_CONFIRM_(INTENT|OUTLINE|DETAIL):/;

function extractAssistantText(transcript) {
  if (!Array.isArray(transcript)) return "";
  const parts = [];
  for (const turn of transcript) {
    if (!turn || turn.role !== "assistant") continue;
    const c = turn.content;
    if (typeof c === "string") {
      parts.push(c);
    } else if (Array.isArray(c)) {
      for (const item of c) {
        if (item && item.type === "text" && typeof item.text === "string") parts.push(item.text);
      }
    }
  }
  return parts.join("\n");
}

function collectAuditCandidates(transcript, state) {
  const au = (state && state.audit) || {};

  // Terminal/in-flight states: never (re)arm.
  if (au.audit_phase === "frozen") return { shouldArm: false, cause: null };
  if (au.audit_phase === "pending" || au.audit_phase === "in_progress") return { shouldArm: false, cause: null };

  // Trigger (a): stage-boundary sentinel.
  const text = extractAssistantText(transcript);
  const stageMatch = CONFIRM_RE.exec(text);
  if (stageMatch) {
    return { shouldArm: true, cause: `stage-boundary:CONFIRM_${stageMatch[1]}` };
  }

  // Trigger (b): cumulative severity threshold.
  const cumSev = state && state.alert && state.alert.cumulative_severity;
  if (cumSev && SEVERITY_RANK[cumSev] >= SEVERITY_RANK[AUDIT_SEVERITY_THRESHOLD]) {
    return { shouldArm: true, cause: `severity-threshold:${cumSev}` };
  }

  return { shouldArm: false, cause: null };
}

module.exports = { collectAuditCandidates };
