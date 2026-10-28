"use strict";

// A PreToolUse hook sits in front of the user's keystroke, so every probe this
// guard makes shares the hook's one decision time limit (hooks/lib/decision-time-limit.js)
// instead of a per-probe timeout that multiplies with the command count. The
// recorded spend is charged against the same limit, so an unarmed caller (a test,
// a library use) is bounded the same way. Below MIN_PROBE_MS a probe cannot
// realistically complete, so probing is declined instead of started and killed.
const { DECISION_TIME_LIMIT_MS, remainingDecisionMs } = require("../lib/decision-time-limit");

const MIN_PROBE_MS = 250;

function createBudget() {
  return { startedAt: Date.now(), spentMs: 0 };
}

// Remaining time for ONE probe, capped at capMs, or null when too little is left
// or the budget is absent. `spentMs` and elapsed wall-clock are both consulted and
// the larger wins: a caller that forgets to record a probe still gets charged.
function probeTimeout(budget, capMs) {
  if (!budget || typeof budget !== "object") return null;
  const started = typeof budget.startedAt === "number" ? budget.startedAt : Date.now();
  const spent = Math.max(budget.spentMs || 0, Date.now() - started);
  const remaining = Math.min(remainingDecisionMs(), DECISION_TIME_LIMIT_MS - spent);
  if (remaining < MIN_PROBE_MS) return null;
  const cap = typeof capMs === "number" && capMs > 0 ? capMs : remaining;
  return Math.floor(Math.min(cap, remaining));
}

function chargeBudget(budget, ms) {
  if (!budget || typeof budget !== "object") return;
  budget.spentMs = (budget.spentMs || 0) + (typeof ms === "number" && ms > 0 ? ms : 0);
}

module.exports = { createBudget, probeTimeout, chargeBudget, MIN_PROBE_MS };
