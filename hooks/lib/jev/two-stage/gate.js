"use strict";
// hooks/lib/jev/two-stage/gate.js — the per-direction confidence gate shared by every
// judgment point (#2460). Pure: the outcome depends only on the policy's
// confidence_threshold_by_answer and short_circuit_answer, plus the point's optional
// decisiveness hook (#2677); there is no built-in threshold. A direction whose threshold is
// null (not a number) holds every answer in that direction for the backup subagent.

// Keeps float error (1 - 0.3) from moving a boundary value across the threshold.
const CONFIDENCE_EPSILON = 1e-9;

// The short circuit fires on the adopted keys whose value is short_circuit_answer: by value
// alone, or, when the point hands hooks.decides(keys), only when that returns true.
function shortCircuitOf(adopted, sc, hooks) {
  if (sc === null || sc === undefined) return false;
  const hits = Object.keys(adopted).filter((k) => adopted[k] === sc);
  if (hits.length === 0) return false;
  if (!hooks || typeof hooks.decides !== "function") return true;
  try {
    return hooks.decides(hits) === true;
  } catch (_e) {
    return false;
  }
}

// applyGate({key: {p}}, policy, hooks?) -> {adopted, delegated, unjudged, short_circuited, result}.
function applyGate(items, policy, hooks) {
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
  if (shortCircuitOf(adopted, sc, hooks)) {
    return { adopted, delegated: [], unjudged: held, short_circuited: true, result: "final" };
  }
  return {
    adopted, delegated: held, unjudged: [], short_circuited: false,
    result: held.length === 0 ? "final" : "need-subagent",
  };
}

module.exports = { CONFIDENCE_EPSILON, applyGate };
