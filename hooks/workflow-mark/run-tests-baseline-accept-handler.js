"use strict";
// Issue #2517 — WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED.
//
//   echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: {reason}>>"
// Records the user's grant that a failing run_tests holds only pre-existing failures the
// baseline could not prove. It writes ONE baseline_accept annotation bound to the current run
// and never completes the step: bin/run-tests-baseline re-checks it and completes. The verdict is
// read from recorded annotations only (CPR-SSOT); check and write share one appendEvents builder.

const { RUN_TESTS_BASELINE_ACCEPTED_RE_DQ, RUN_TESTS_BASELINE_ACCEPTED_LOOKSLIKE_RE } =
  require("../lib/sentinel-patterns");
const { appendEvents } = require("../workflow-state/state-io");
const { sanitizeLine } = require("../lib/output-sanitize");
const { grantKind } = require("../../bin/workflow/lib/run-tests-baseline-evidence");

const LABEL = "RUN_TESTS_BASELINE_ACCEPTED";
const ORIGIN = "workflow-mark-run-tests-baseline-accept";
const FORM = "echo \"<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: {reason}>>\"";
const UA_FORM = "echo \"<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>\"";
const FAILING_OUTCOMES = ["fail", "timeout", "runner-error"];

// The grant's kind, or { why } when the run cannot be granted. The early checks only word the
// refusal; grantKind (the CLI accept's own verdict) decides, so the two cannot disagree (CPR-SSOT).
function judge(entry) {
  if (!entry) return { why: "no /run-tests run is recorded — nothing pending to accept" };
  if (entry.status !== "pending") return { why: `run_tests is already ${entry.status} — nothing pending to accept` };
  if (entry.run_outcome === "unrunnable") {
    return { why: `the run is UNRUNNABLE-only, not failing — use ${UA_FORM}` };
  }
  if (!FAILING_OUTCOMES.includes(entry.run_outcome)) {
    return { why: `run_outcome=${entry.run_outcome || "none"} is not a failing run` };
  }
  if (Number.isInteger(entry.unrunnable_count) && entry.unrunnable_count > 0) {
    return { why: `${entry.unrunnable_count} selected test(s) are UNRUNNABLE — install the runtimes or use ${UA_FORM}` };
  }
  if (entry.unrunnable_count !== 0) {
    return { why: "the failing run recorded no exact unrunnable_count of 0 — re-run /run-tests" };
  }
  const kind = grantKind(entry);
  if (kind !== null) return { kind };
  const cls = entry.baseline_classification;
  if (!cls || !Array.isArray(cls.entries)) {
    return { why: "no baseline classification is recorded — run bin/run-tests-baseline first" };
  }
  if (cls.entries.some((e) => e && e.class === "broken")) {
    return { why: "the baseline classified a test as broken — a broken test cannot be accepted" };
  }
  return {
    why: "the baseline classification does not support a grant — it must cover every failing path exactly " +
      "and leave only undetermined tests not pre-existing",
  };
}

function rejection(entry) {
  const j = judge(entry);
  return j.why || null;
}

function annotation(entry, kind, reason) {
  const value = {
    reason,
    kind,
    run_seq: entry.updated_seq,
    outcome_source: entry.outcome_source === undefined ? null : entry.outcome_source,
    accepted_run_outcome: entry.run_outcome,
  };
  return { kind: "step_annotation", step: "run_tests", key: "baseline_accept", value, provenance: "declared", origin: ORIGIN };
}

function grant(sessionId, reason) {
  const verdict = { why: "state was not examined", kind: null };
  appendEvents(sessionId, (_events, current) => {
    const entry = (current && current.steps && current.steps.run_tests) || null;
    const j = judge(entry);
    verdict.why = j.why || null;
    verdict.kind = j.kind || null;
    if (verdict.why !== null) return [];
    return [annotation(entry, j.kind, reason)];
  });
  return verdict;
}

function grantMessage(sessionId, kind) {
  const head = `[workflow] ${LABEL}: grant recorded (kind=${kind}); run_tests stays pending. ` +
    `Re-run bin/run-tests-baseline --session ${sessionId} to complete run_tests.`;
  if (kind !== "failing-list-unrecorded") return head;
  return head + " With no recorded failing list, a broken test among the failures cannot be told apart.";
}

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;
  const m = cmd.match(RUN_TESTS_BASELINE_ACCEPTED_RE_DQ);
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
      const v = grant(sessionId, reason);
      if (v.why !== null) {
        pushMessage(`workflow-mark: ${LABEL} rejected — ${v.why}; state unchanged.`);
        return true;
      }
      pushMessage(grantMessage(sessionId, v.kind));
    } catch (e) {
      pushMessage(`workflow-mark: failed to write state — ${e.message}. ${LABEL} NOT recorded.`);
    }
    return true;
  }
  if (RUN_TESTS_BASELINE_ACCEPTED_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed WORKFLOW_${LABEL} — expected: ${FORM} ` +
        "{reason} must not contain ( ) ; | & > or a backtick."
    );
    return true;
  }
  return false;
}

module.exports = { handle, rejection };
