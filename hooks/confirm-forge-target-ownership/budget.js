"use strict";

// A PreToolUse hook sits in front of the user's keystroke: every millisecond it
// spends is latency the user pays before their command runs. So the guard gets
// ONE wall-clock budget for the whole invocation, shared by every probe it may
// make, rather than a per-probe timeout that multiplies with the command count.
// RESERVE_MS is held back for the hook's own emit path so a probe that runs to
// the very edge still leaves room to answer; below MIN_PROBE_MS a probe cannot
// realistically complete, so probing is declined instead of started and killed.
const BUDGET_MS = 4000;
const RESERVE_MS = 400;
const MIN_PROBE_MS = 250;

function createBudget() {
  return { startedAt: Date.now(), spentMs: 0 };
}

// Remaining time for ONE probe, capped at capMs, or null when the budget is
// exhausted / absent. `spentMs` and elapsed wall-clock are both consulted and
// the larger wins: a caller that forgets to record a probe still gets charged.
function probeTimeout(budget, capMs) {
  if (!budget || typeof budget !== "object") return null;
  const started = typeof budget.startedAt === "number" ? budget.startedAt : Date.now();
  const spent = Math.max(budget.spentMs || 0, Date.now() - started);
  const remaining = BUDGET_MS - spent - RESERVE_MS;
  if (remaining < MIN_PROBE_MS) return null;
  const cap = typeof capMs === "number" && capMs > 0 ? capMs : remaining;
  return Math.min(cap, remaining);
}

function chargeBudget(budget, ms) {
  if (!budget || typeof budget !== "object") return;
  budget.spentMs = (budget.spentMs || 0) + (typeof ms === "number" && ms > 0 ? ms : 0);
}

module.exports = { createBudget, probeTimeout, chargeBudget, BUDGET_MS, RESERVE_MS, MIN_PROBE_MS };
