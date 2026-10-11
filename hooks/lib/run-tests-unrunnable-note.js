"use strict";
// The one line an UNRUNNABLE accept (#2501 D5-7) leaves in the Final Report and the PR body:
// how many selected tests never ran, which runtimes were missing, and why it was accepted.
// Read from the run_tests annotations only (CPR-SSOT); a later run tombstones them, so a
// session whose final run was green prints nothing.

const path = require("path");

const ACCEPT_BASIS = "unrunnable-accepted";

function oneLine(v) {
  return String(v).replace(/[\r\n]+/g, " ").slice(0, 200);
}

// unrunnableAcceptNote(entry) — the line for a run_tests entry, or null when it was not accepted.
function unrunnableAcceptNote(entry) {
  if (!entry || entry.status !== "complete" || entry.completion_basis !== ACCEPT_BASIS) return null;
  const count = Number.isInteger(entry.unrunnable_count) ? entry.unrunnable_count : "?";
  const runtimes = entry.unrunnable_runtimes ? oneLine(entry.unrunnable_runtimes) : "unknown";
  const reason = entry.unrunnable_accept_reason ? oneLine(entry.unrunnable_accept_reason) : "(none)";
  return `- Unverified tests: ${count} UNRUNNABLE accepted (missing runtimes: ${runtimes}; reason: ${reason})`;
}

// readUnrunnableAcceptNote(sessionId) — the same line from the session's state; null on any error.
function readUnrunnableAcceptNote(sessionId) {
  try {
    const { readState } = require(path.join(__dirname, "..", "workflow-state", "state-io"));
    const state = readState(sessionId);
    return unrunnableAcceptNote(state && state.steps && state.steps.run_tests);
  } catch (e) {
    return null;
  }
}

module.exports = { ACCEPT_BASIS, unrunnableAcceptNote, readUnrunnableAcceptNote };
