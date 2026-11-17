"use strict";
// approval.js — the user approval of failing tests the base could not observe (#3067).
// `record` prints approvalHint on exit 1 / 8; the workflow-mark handler for
// WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED checks approvalRejection and writes
// approvalEvents inside one appendEvents builder. What is approvable lives in disposition.js.

const path = require("path");
const disposition = require(path.join(__dirname, "disposition"));
const pre = require(path.join(__dirname, "preconditions"));
const { BASELINE_UNOBSERVED_BASIS } =
  require(path.join(__dirname, "..", "..", "..", "..", "hooks", "lib", "run-tests-completion-note"));

const APPROVAL_SENTINEL_FORM = "echo \"<<WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED: {reason}>>\"";
const HEAD_RE = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const RERUN_BASELINE = "re-run bin/run-tests-baseline in the session's worktree";

function classificationOf(entry) {
  const c = entry && entry.baseline_classification;
  return c && typeof c === "object" && Array.isArray(c.entries) ? c : null;
}

// approvalHint(entry, entries) — the stderr text offering the approval, or null when not approvable.
function approvalHint(entry, entries) {
  if (pre.unrunnablePrecondition(entry) !== null) return null;
  const a = disposition.approvable(entries);
  if (!a.ok) return null;
  const details = [...new Set(a.rows.map((e) => e.detail))].join(", ");
  return `\n${a.rows.length} failing test(s) were never observed at the base (${details}). ` +
    `If the user approves them without a base observation, run: ${APPROVAL_SENTINEL_FORM}`;
}

// approvalRejection({ sessionId, entry, currentHead }) — why the approval is refused, or null.
function approvalRejection({ sessionId, entry, currentHead }) {
  const why = pre.failingPrecondition(entry) || pre.dispatchPrecondition(sessionId, entry);
  if (why !== null) return why;
  const unrunnable = pre.unrunnablePrecondition(entry);
  if (unrunnable !== null) return unrunnable;
  const c = classificationOf(entry);
  if (c === null) return "no baseline classification is recorded; run bin/run-tests-baseline first";
  if (typeof c.head !== "string" || !HEAD_RE.test(c.head)) {
    return `the classification records no HEAD (recorded before #3067); ${RERUN_BASELINE}`;
  }
  if (c.head !== currentHead) {
    return `HEAD moved since the classification (classified at ${c.head.slice(0, 7)}, ` +
      `HEAD is ${String(currentHead).slice(0, 7)}); ${RERUN_BASELINE}`;
  }
  const cover = pre.coverStatus(entry.failing_tests, c.entries);
  if (!cover.covered) {
    return `classification does not cover failing_tests (missing=${cover.missing.length}, foreign=${cover.foreign.length})`;
  }
  const a = disposition.approvable(c.entries);
  if (a.blocking.length > 0) {
    const details = [...new Set(a.blocking.map((e) => e.detail))].join(", ");
    return `${a.blocking.length} failing test(s) are not approvable (${details}); fix them or prove them pre-existing`;
  }
  if (a.rows.length === 0) return "no failing test is awaiting an approval";
  return null;
}

// approvalEvents(entry, reason, origin) — the events that complete run_tests on the approval.
function approvalEvents(entry, reason, origin) {
  const c = classificationOf(entry);
  const tests = disposition.approvable(c.entries).rows.map((e) => ({ path: e.path, class: e.class, detail: e.detail }));
  const annotation = (key, value) => ({ kind: "step_annotation", step: "run_tests", key, value, provenance: "declared", origin });
  // run_outcome "pass": a failing value would make write-code-resume reopen write_code.
  return [
    annotation("run_outcome", "pass"),
    annotation("completion_basis", BASELINE_UNOBSERVED_BASIS),
    annotation("baseline_unobserved_accept", { reason, head: c.head, tests }),
    { kind: "step_status", step: "run_tests", status: "complete", provenance: "declared", origin },
  ];
}

module.exports = { APPROVAL_SENTINEL_FORM, HEAD_RE, approvalHint, approvalRejection, approvalEvents };
