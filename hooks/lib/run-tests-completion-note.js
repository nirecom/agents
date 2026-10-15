"use strict";
// The one line a run_tests completed by a user accept leaves in the Final Report and the PR
// body: UNRUNNABLE accept (#2501 D5-7) or baseline accept grant (#2517). Read from the run_tests
// annotations only (CPR-SSOT); a later run tombstones them, so a session whose final run was
// green prints nothing. baseline-preexisting (a proof, not an accept) is not disclosed.

const path = require("path");

const UNRUNNABLE_ACCEPT_BASIS = "unrunnable-accepted";
const BASELINE_ACCEPT_BASIS = "baseline-user-accepted";

function oneLine(v) {
  return String(v).replace(/[\r\n]+/g, " ").slice(0, 200);
}

function unrunnableLine(entry) {
  const count = Number.isInteger(entry.unrunnable_count) ? entry.unrunnable_count : "?";
  const runtimes = entry.unrunnable_runtimes ? oneLine(entry.unrunnable_runtimes) : "unknown";
  const reason = entry.unrunnable_accept_reason ? oneLine(entry.unrunnable_accept_reason) : "(none)";
  return `- Unverified tests: ${count} UNRUNNABLE accepted (missing runtimes: ${runtimes}; reason: ${reason})`;
}

// run_outcome is "pass" once accept() completes the step; the failing value lives on the grant.
function baselineLine(entry) {
  const grant = entry.baseline_accept && typeof entry.baseline_accept === "object" ? entry.baseline_accept : {};
  const reason = grant.reason ? oneLine(grant.reason) : "(none)";
  if (grant.kind === "failing-list-unrecorded") {
    const ro = typeof grant.accepted_run_outcome === "string" && grant.accepted_run_outcome
      ? oneLine(grant.accepted_run_outcome) : "unknown";
    return `- Unverified tests: failing tests accepted by the user with no recorded failing list (run_outcome=${ro}; reason: ${reason})`;
  }
  const entries = (entry.baseline_classification && Array.isArray(entry.baseline_classification.entries))
    ? entry.baseline_classification.entries : [];
  const undetermined = entries.filter((e) => e && e.class === "undetermined");
  const details = [...new Set(undetermined.map((e) => e.detail).filter(Boolean))].join(", ") || "unknown";
  return `- Unverified tests: ${undetermined.length} failing test(s) accepted by the user as pre-existing ` +
    `without baseline proof (undetermined: ${oneLine(details)}; reason: ${reason})`;
}

// completionNote(entry) — the line for a run_tests entry, or null when no accept completed it.
function completionNote(entry) {
  if (!entry || entry.status !== "complete") return null;
  if (entry.completion_basis === UNRUNNABLE_ACCEPT_BASIS) return unrunnableLine(entry);
  if (entry.completion_basis === BASELINE_ACCEPT_BASIS) return baselineLine(entry);
  return null;
}

// readCompletionNote(sessionId) — the same line from the session's state; null on any error.
function readCompletionNote(sessionId) {
  try {
    const { readState } = require(path.join(__dirname, "..", "workflow-state", "state-io"));
    const state = readState(sessionId);
    return completionNote(state && state.steps && state.steps.run_tests);
  } catch (e) {
    return null;
  }
}

module.exports = { UNRUNNABLE_ACCEPT_BASIS, BASELINE_ACCEPT_BASIS, completionNote, readCompletionNote };
