"use strict";
// preconditions.js — what a run_tests entry must satisfy before a baseline classification can
// complete it. Shared by `record` (run-tests-baseline-evidence.js) and the user approval
// (approval.js, #3067) so both refuse on the same definitions.

const path = require("path");

// "unrunnable" is excluded: a missing runtime is fixed by installing it, never by a baseline.
const FAILING_OUTCOMES = ["fail", "timeout", "runner-error"];
const NO_LIST = "failing_tests is not a non-empty list";
const HITS_WHY = "the run left unattributed hits (HITS>0); no failure in it can be classified";

// The recorded hit_count when it is a positive integer, else 0.
function hitCount(entry) {
  const n = entry ? entry.hit_count : undefined;
  return Number.isInteger(n) && n > 0 ? n : 0;
}

// Why the entry cannot be baseline-classified, or null when it can.
function failingPrecondition(entry) {
  if (!entry) return "run_tests has no state entry";
  if (entry.status !== "pending") return `run_tests status is ${entry.status}, not pending`;
  if (hitCount(entry) > 0) return HITS_WHY;
  if (!FAILING_OUTCOMES.includes(entry.run_outcome)) return "run_outcome is not a failing value";
  const ft = entry.failing_tests;
  if (!Array.isArray(ft) || ft.length === 0) return NO_LIST;
  if (!ft.every((p) => typeof p === "string" && p !== "")) return "failing_tests holds a non-path entry";
  return null;
}

function settlement() {
  return require(path.join(__dirname, "..", "..", "..", "..", "hooks", "workflow-state", "dispatch-settlement"));
}

// #2544: the failing list may come from a dispatch outcome. It stands only while no
// newer test-runner dispatch is unsettled and the outcome it came from is unchanged.
function dispatchPrecondition(sessionId, entry) {
  const s = settlement();
  const { unsettled, reason } = s.listUnsettled({ sessionId });
  if (reason) return reason;
  if (unsettled.some((u) => u.worker === "test-runner")) return "a newer test-runner dispatch has not settled";
  const source = entry.outcome_source;
  if (source === null || source === undefined) return null;
  return s.outcomeSourceStatus({ sessionId, source }) === "match" ? null : "outcome source changed or missing";
}

// A selected test that never ran (UNRUNNABLE) proves nothing about itself, so the step stays
// pending however the failures classify; only the hook's own exact 0 clears this (null included).
function unrunnablePrecondition(entry) {
  if (entry.unrunnable_count === 0) return null;
  return Number.isInteger(entry.unrunnable_count)
    ? `${entry.unrunnable_count} selected test(s) were UNRUNNABLE; install the missing runtime and re-run /run-tests`
    : "the failing run recorded no unrunnable_count; re-run /run-tests";
}

// Set cover by path identity: duplicates never stand in for an omitted path.
function coverStatus(failingTests, entries) {
  const want = new Set(failingTests);
  const have = new Set(entries.map((e) => e.path));
  const missing = [...want].filter((p) => !have.has(p));
  const foreign = [...have].filter((p) => !want.has(p));
  return { covered: missing.length === 0 && foreign.length === 0, missing, foreign };
}

module.exports = {
  FAILING_OUTCOMES, NO_LIST, HITS_WHY,
  hitCount, failingPrecondition, dispatchPrecondition, unrunnablePrecondition, coverStatus,
};
