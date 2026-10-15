"use strict";
// Issue #2501 D5-7 — WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED.
//
//   echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>"
// Completes a run_tests left pending ONLY because selected tests could not run (current
// contract, FAIL=0, UNRUNNABLE>0). The verdict is read from the annotations
// workflow-run-tests.js recorded (CPR-SSOT), never from stdout; check and write share one
// appendEvents builder so a newer run cannot slip in between. The next run clears the accept.

const { RUN_TESTS_UNRUNNABLE_ACCEPTED_RE_DQ, RUN_TESTS_UNRUNNABLE_ACCEPTED_LOOKSLIKE_RE } =
  require("../lib/sentinel-patterns");
const { appendEvents } = require("../workflow-state/state-io");
const { sanitizeLine } = require("../lib/output-sanitize");
const { UNRUNNABLE_ACCEPT_BASIS } = require("../lib/run-tests-completion-note");

const LABEL = "RUN_TESTS_UNRUNNABLE_ACCEPTED";
const ORIGIN = "workflow-mark-run-tests-accept";
const FORM = "echo \"<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>\"";

// Why `entry` cannot be accepted, or null when it can. Order: settled, failed, unread, legacy.
function rejection(entry) {
  if (!entry) return "no /run-tests run is recorded (no RUN_CONTRACT to accept)";
  if (entry.status !== "pending") return `run_tests is already ${entry.status} — nothing pending to accept`;
  if (entry.last_run_failed === true || entry.run_outcome === "fail") {
    return "the run reported FAIL>0 — a failing test is a code defect, not an unrunnable runtime";
  }
  if (entry.contract_absent === true) return "the run left no trusted RUN_CONTRACT — re-run /run-tests";
  if (entry.run_outcome === "unrunnable" && Number.isInteger(entry.unrunnable_count) && entry.unrunnable_count > 0) {
    return null;
  }
  if (entry.run_outcome === null || entry.run_outcome === undefined) {
    if (entry.unrunnable_count === null || entry.unrunnable_count === undefined) {
      return "a legacy 4-field RUN_CONTRACT cannot prove UNRUNNABLE=0 — rebase onto main and re-run /run-tests";
    }
  }
  return `run_tests is not pending on contract-unrunnable (run_outcome=${entry.run_outcome || "none"})`;
}

function annotation(key, value) {
  return { kind: "step_annotation", step: "run_tests", key, value, provenance: "declared", origin: ORIGIN };
}

function accept(sessionId, reason) {
  const verdict = { why: "state was not examined", entry: null };
  appendEvents(sessionId, (_events, current) => {
    const entry = (current && current.steps && current.steps.run_tests) || null;
    verdict.why = rejection(entry);
    verdict.entry = entry;
    if (verdict.why !== null) return [];
    return [
      annotation("completion_basis", UNRUNNABLE_ACCEPT_BASIS),
      annotation("unrunnable_accept_reason", reason),
      { kind: "step_status", step: "run_tests", status: "complete", provenance: "declared", origin: ORIGIN },
    ];
  });
  return verdict;
}

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;
  const m = cmd.match(RUN_TESTS_UNRUNNABLE_ACCEPTED_RE_DQ);
  if (m) {
    const reason = sanitizeLine(m[1].trim());
    if (reason.replace(/\s/g, "").length < 3) {
      pushMessage(`workflow-mark: ${LABEL} rejected — reason too short; state unchanged. Re-emit: ${FORM}`);
      return true;
    }
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — ${LABEL} NOT recorded.`);
      return true;
    }
    try {
      const v = accept(sessionId, reason);
      if (v.why !== null) {
        pushMessage(`workflow-mark: ${LABEL} rejected — ${v.why}; state unchanged.`);
        return true;
      }
      const runtimes = v.entry.unrunnable_runtimes || "unknown";
      pushMessage(
        `[workflow] ${LABEL}: run_tests complete with ${v.entry.unrunnable_count} UNRUNNABLE test(s) ` +
          `(missing runtimes: ${runtimes}). The Final Report and PR body must say so.`
      );
    } catch (e) {
      pushMessage(`workflow-mark: failed to write state — ${e.message}. ${LABEL} NOT recorded.`);
    }
    return true;
  }
  if (RUN_TESTS_UNRUNNABLE_ACCEPTED_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed WORKFLOW_${LABEL} — expected: ${FORM} ` +
        "{reason} must not contain ( ) ; | & > or a backtick."
    );
    return true;
  }
  return false;
}

module.exports = { handle, rejection };
