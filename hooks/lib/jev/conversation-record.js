"use strict";
// hooks/lib/jev/conversation-record.js — the v2 decision record of a conversation-class point.
// Same field set as the stage points' records; a conversation point has no ticket, stage,
// tool_use_id or backup subagent, so those read null and llm_needed is always false.

const path = require("path");
const record = require("./decision-record");

// The workflow step current when the point was judged, or null (no state, an unreadable state).
function currentStep(sessionId) {
  try {
    const step = require(path.join(__dirname, "..", "..", "workflow-state", "current-step.js")).resolveCurrentEffectiveStep(sessionId);
    return typeof step === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(step) ? step : null;
  } catch (_e) {
    return null;
  }
}

// jev: {status, http_status, probabilities, latency_ms, model, input_tokens, est_cost_usd}.
function jevBlock(jev, probabilities) {
  const j = jev || {};
  const ps = probabilities ? Object.values(probabilities).filter((p) => typeof p === "number") : [];
  return {
    status: typeof j.status === "string" ? j.status : "not-run",
    http_status: Number.isInteger(j.http_status) ? j.http_status : null,
    answer: null,
    probabilities: probabilities || null,
    min_confidence: ps.length ? Math.min(...ps.map((p) => Math.max(p, 1 - p))) : null,
    latency_ms: record.boundedLatency(j.latency_ms),
    model: typeof j.model === "string" ? j.model : null,
    input_tokens: Number.isSafeInteger(j.input_tokens) ? j.input_tokens : null,
    est_cost_usd: typeof j.est_cost_usd === "number" && Number.isFinite(j.est_cost_usd) ? j.est_cost_usd : null,
  };
}

// buildConversationRecord({point, entry, sessionId, judgedIn, input, jev, probabilities, adopted,
// final, fallbackReason, now}) -> the record; appendConversationRecord writes it (best effort).
function buildConversationRecord(o) {
  const e = o.entry || {};
  const t = e.confidence_threshold_by_answer || null;
  return {
    version: record.DECISION_RECORD_VERSION,
    record_type: "decision",
    ts: new Date(o.now || Date.now()).toISOString(),
    point: o.point,
    judged_in: record.judgedInOr(o.judgedIn, null),
    mode: typeof e.mode === "string" ? e.mode : null,
    adopted: o.adopted === "jev" ? "jev" : null,
    threshold: t ? { true: t.true, false: t.false } : null,
    short_circuit_answer: Object.prototype.hasOwnProperty.call(e, "short_circuit_answer") ? e.short_circuit_answer : null,
    short_circuited: false,
    unjudged_keys: [],
    session_id: o.sessionId,
    step: currentStep(o.sessionId),
    stage: null,
    ticket: null,
    tool_use_id: null,
    input: Object.assign({ bytes: 0, sha256: null, truncated: false, sources: [] }, o.input || {}),
    deterministic: null,
    jev: jevBlock(o.jev, o.probabilities),
    llm_needed: false,
    llm_answer_received: false,
    llm: null,
    final: o.final === undefined ? null : o.final,
    agreement: null,
    agreement_by_signal: null,
    fallback_reason: o.fallbackReason === undefined ? null : o.fallbackReason,
  };
}

function appendConversationRecord(o) {
  try {
    record.appendDecision(buildConversationRecord(o));
  } catch (_e) { /* best effort: an unwritable log never breaks the caller */ }
}

module.exports = { buildConversationRecord, appendConversationRecord };
