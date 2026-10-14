"use strict";
// hooks/lib/jev/two-stage/gate.js — the per-direction confidence gate shared by every
// judgment point (#2460). Pure: the outcome depends only on the policy's
// confidence_threshold_by_answer and short_circuit_answer; there is no built-in threshold.

// Keeps float error (1 - 0.3) from moving a boundary value across the threshold.
const CONFIDENCE_EPSILON = 1e-9;

// applyGate({key: {p}}, policy) -> {adopted, delegated, unjudged, short_circuited, result}.
function applyGate(items, policy) {
  const byAnswer = (policy && policy.confidence_threshold_by_answer) || {};
  const sc = policy && Object.prototype.hasOwnProperty.call(policy, "short_circuit_answer")
    ? policy.short_circuit_answer : null;
  const adopted = {};
  const held = [];
  for (const key of Object.keys(items || {})) {
    const p = items[key] && items[key].p;
    const th = byAnswer[String(p >= 0.5)];
    if (typeof p !== "number" || !Number.isFinite(p) || typeof th !== "number") {
      held.push(key);
      continue;
    }
    const answer = p >= 0.5;
    const conf = Math.max(p, 1 - p);
    if (conf >= th - CONFIDENCE_EPSILON) adopted[key] = answer;
    else held.push(key);
  }
  const shortCircuited = sc !== null && sc !== undefined && Object.values(adopted).some((v) => v === sc);
  if (shortCircuited) {
    return { adopted, delegated: [], unjudged: held, short_circuited: true, result: "final" };
  }
  return {
    adopted, delegated: held, unjudged: [], short_circuited: false,
    result: held.length === 0 ? "final" : "need-subagent",
  };
}

module.exports = { CONFIDENCE_EPSILON, applyGate };
