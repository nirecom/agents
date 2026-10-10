"use strict";
// hooks/workflow-run-tests/record-run.js — the only run_tests writer of the hook.
// Both routes (Bash stdout, dispatch outcome file) record through recordRun, so a
// run is judged by one predicate wherever its result came from (#2544).
// Trust model: docs/architecture/claude-code/settings/hooks.md.

const { markStep, readState } = require("../workflow-state");
const { isContractTrusted, resolveRunOutcome } = require("./outcome");
const { stampTestFailureRisk } = require("./test-failure-risk");

// Baseline evidence (#2431) belongs to ONE observed failing run: any new run
// clears it, so a later completion can never inherit an older classification.
const BASELINE_TOMBSTONES = { baseline_classification: null, completion_basis: null };

const DEMOTION_HINT =
  "Completion requires tests/run-all.sh (or the worker-dispatch test-runner) " +
  "and exactly one valid RUN_CONTRACT line in its output.";

// outcome_source names the outcome file a record came from (null on stdout);
// dispatch_unsettled names a dispatch whose outcome has not arrived yet.
function sourceFields(source, unsettledStem) {
  return { outcome_source: source || null, dispatch_unsettled: unsettledStem || null };
}

function recordFailedExit(r) {
  markStep(r.sessionId, "run_tests", "pending", {
    last_run_failed: true,
    last_exit_code: r.exitCode,
    trigger_command: r.triggerCommand,
    run_outcome: r.runOutcome,
    failing_tests: r.failingTests,
    ...BASELINE_TOMBSTONES,
    ...sourceFields(r.source, r.unsettledStem),
  });
  // #2430: a red suite outside the red-expected steps is a handoff risk. Never throws.
  if (r.stampRisk) stampTestFailureRisk(r.sessionId);
  return null;
}

// Returns the human-facing diagnostic; nothing reads it back as a judgement input.
function recordDemotion(r) {
  markStep(r.sessionId, "run_tests", "pending", {
    last_run_failed: false,
    contract_absent: r.contractAbsent,
    trigger_command: r.triggerCommand,
    run_outcome: r.runOutcome,
    failing_tests: r.failingTests,
    ...BASELINE_TOMBSTONES,
    ...sourceFields(r.source, r.unsettledStem),
  });
  return `run_tests demoted to pending (${r.reason}). ${DEMOTION_HINT}`;
}

// The PR #1165 guard: complete only once write_tests is complete or skipped.
function recordPass(r) {
  const state = readState(r.sessionId);
  const wt = state && state.steps && state.steps.write_tests ? state.steps.write_tests.status : undefined;
  if (wt !== "complete" && wt !== "skipped") return null;
  // Null annotations are tombstones (#1733); the origin marks pattern detection (#1794).
  markStep(r.sessionId, "run_tests", "complete", {
    last_run_failed: null,
    last_exit_code: null,
    contract_absent: null,
    trigger_command: null,
    run_outcome: "pass",
    failing_tests: null,
    ...BASELINE_TOMBSTONES,
    ...sourceFields(r.source, null),
  }, { origin: "workflow-run-tests-auto-detect" });
  return null;
}

// A dispatch is in flight: no earlier result may stand for it until its outcome lands.
function recordUnsettled({ sessionId, stem, triggerCommand }) {
  return recordDemotion({
    sessionId,
    contractAbsent: null,
    triggerCommand,
    runOutcome: null,
    failingTests: null,
    source: null,
    unsettledStem: stem,
    reason: "dispatch-unsettled",
  });
}

function defaultReason(input) {
  if (input.vetoed === true) return "worker-status-veto";
  return input.contract === null || input.contract === undefined ? "contract-absent" : "contract-invalid";
}

// -> the systemMessage to surface, or null. `unsettledStem` blocks completion:
// while a dispatch is unsettled a run may take run_tests away, never grant it,
// and records no observation that could stand for that dispatch.
function recordRun(r) {
  const input = r.outcomeInput || {};
  const contract = input.contract === undefined ? null : input.contract;
  const unsettledStem = r.unsettledStem || null;
  const base = {
    sessionId: r.sessionId,
    exitCode: r.exitCode,
    triggerCommand: r.triggerCommand,
    runOutcome: unsettledStem === null ? resolveRunOutcome(input) : null,
    failingTests: unsettledStem === null && r.failingTests !== undefined ? r.failingTests : null,
    source: r.source || null,
    unsettledStem,
    stampRisk: r.stampRisk === true,
    contractAbsent: r.contractAbsent === undefined ? contract === null : r.contractAbsent,
  };
  if (r.exitCode !== 0) return recordFailedExit(base);
  if (unsettledStem !== null) return recordDemotion(Object.assign(base, { reason: "dispatch-unsettled" }));
  if (!(isContractTrusted(input) && contract.fail === 0)) {
    return recordDemotion(Object.assign(base, { reason: r.reason || defaultReason(input) }));
  }
  return recordPass(base);
}

module.exports = { BASELINE_TOMBSTONES, recordRun, recordUnsettled };
