"use strict";

// #2256 S3 — Audit mode trigger collector. Trigger table + cause labels: hooks/lib/audit-triggers.js.
// TR1-TR5 are edge triggers on an unconsumed step transition `<step>#<updated_seq>`; TR6 is the
// level trigger. Two call shapes: (projection, state) -> array (canonical, coalescing needs all
// candidates); (transcript, state) -> { shouldArm, cause } for the stage-sentinel Stop path.

const { AUDIT_SEVERITY_THRESHOLD, SEVERITY_RANK } = require("../lib/supervisor-state-schema");
const triggers = require("../lib/audit-triggers");

const CONFIRM_RE = /<<WORKFLOW_CONFIRM_(INTENT|OUTLINE|DETAIL):/;

// Stage sentinel -> the workflow step whose completion it announces.
const SENTINEL_STEP = {
  INTENT: "clarify_intent",
  OUTLINE: "outline",
  DETAIL: "detail",
};

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

// Terminal / in-flight audit states never (re)arm.
function isQuiescent(audit) {
  const phase = audit.audit_phase;
  return phase !== "frozen" && phase !== "pending" && phase !== "in_progress" && phase !== "done";
}

function severityCandidate(state) {
  const cumSev = state && state.alert && state.alert.cumulative_severity;
  if (!cumSev) return null;
  if (SEVERITY_RANK[cumSev] <= SEVERITY_RANK["warning"]) return null;
  const tr = triggers.triggerById("TR6");
  return {
    tr_id: "TR6",
    step: null,
    transition: null,
    cause: `${triggers.SEVERITY_THRESHOLD_PREFIX}${cumSev}`,
    sub_checks: tr ? tr.sub_checks.slice() : [],
  };
}

// Projection form: every complete step whose transition key is still unconsumed.
function candidatesFromProjection(projection, state) {
  const audit = (state && state.audit) || {};
  if (!isQuiescent(audit)) return [];

  const consumed = new Set(Array.isArray(audit.consumed_transitions) ? audit.consumed_transitions : []);
  const steps = (projection && projection.steps) || {};
  const out = [];

  for (const trigger of triggers.TRIGGERS) {
    if (trigger.kind !== "edge") continue;
    const entry = steps[trigger.step];
    if (!entry || entry.status !== "complete") continue;
    const seq = entry.updated_seq;
    if (seq === null || seq === undefined) continue;
    const key = triggers.transitionKey(trigger.step, seq);
    if (consumed.has(key)) continue;
    out.push({
      tr_id: trigger.tr_id,
      step: trigger.step,
      transition: key,
      cause: trigger.cause,
      sub_checks: trigger.sub_checks.slice(),
    });
  }

  const sev = severityCandidate(state);
  if (sev) out.push(sev);
  return out;
}

// Transcript form: the stage sentinel stands in for the step completion the
// projection has not yet recorded at Stop time.
function candidateFromTranscript(transcript, state) {
  const audit = (state && state.audit) || {};
  if (!isQuiescent(audit)) return { shouldArm: false, cause: null };

  const match = CONFIRM_RE.exec(extractAssistantText(transcript));
  if (match) {
    const step = SENTINEL_STEP[match[1]];
    const trigger = triggers.triggerForStep(step);
    return {
      shouldArm: true,
      cause: triggers.stepCompleteCause(step),
      tr_ids: trigger ? [trigger.tr_id] : [],
      sub_checks: trigger ? trigger.sub_checks.slice() : [],
    };
  }

  const sev = severityCandidate(state);
  if (sev) return { shouldArm: true, cause: sev.cause, tr_ids: ["TR6"], sub_checks: sev.sub_checks };

  return { shouldArm: false, cause: null };
}

function collectAuditCandidates(source, state) {
  if (source && !Array.isArray(source) && typeof source === "object" && source.steps) {
    return candidatesFromProjection(source, state);
  }
  return candidateFromTranscript(source, state);
}

module.exports = {
  collectAuditCandidates,
  candidatesFromProjection,
  candidateFromTranscript,
  AUDIT_SEVERITY_THRESHOLD,
};
