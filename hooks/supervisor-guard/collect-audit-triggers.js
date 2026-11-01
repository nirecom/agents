"use strict";

// #2256 S3 — Audit mode trigger collector. Trigger table + cause labels: hooks/lib/audit-triggers.js.
// TR4-TR5 are edge triggers on an unconsumed step transition `<step>#<updated_seq>`; TR6 is the
// level trigger. TR1-TR3 (kind "pre-confirm") never arm here: the plan-stage confirm gate arms
// them through hooks/lib/pre-confirm-audit.js (#2853). One call shape: (projection, state) -> array.

const { AUDIT_SEVERITY_THRESHOLD, SEVERITY_RANK, UNSETTLED_AUDIT_PHASES } = require("../lib/supervisor-state-schema");
const triggers = require("../lib/audit-triggers");
const { unshownRun } = require("../lib/audit-ledger");

// In-flight (UNSETTLED_AUDIT_PHASES) and done audit states never (re)arm. An unshown run (#2698)
// counts as quiescent: no agent runs it, and a newer arm may supersede it.
function isQuiescent(audit) {
  if (unshownRun(audit)) return true;
  const phase = audit.audit_phase;
  return !UNSETTLED_AUDIT_PHASES.includes(phase) && phase !== "done";
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

// A source that is not a projection yields no candidate.
function collectAuditCandidates(source, state) {
  if (source && !Array.isArray(source) && typeof source === "object" && source.steps) {
    return candidatesFromProjection(source, state);
  }
  return [];
}

module.exports = {
  collectAuditCandidates,
  candidatesFromProjection,
  AUDIT_SEVERITY_THRESHOLD,
};
