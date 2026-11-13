"use strict";
// hooks/workflow-run-tests/record-run.js — the only run_tests writer of the hook.
// Both routes (Bash stdout, dispatch outcome file) record through recordRun, so a
// run is judged by one predicate wherever its result came from (#2544).
// Trust model: docs/architecture/claude-code/settings/hooks.md.

const { markStep, readState } = require("../workflow-state");
const { isContractTrusted, resolveRunOutcome } = require("./outcome");
const { demotionReason, demotionMessage } = require("./demotion");
const { stampTestFailureRisk } = require("./test-failure-risk");
const { boundHits } = require("./hit-summary");
const { recordParts } = require("./run-parts");

// Evidence that belongs to ONE observed run: baseline (#2431), an UNRUNNABLE accept
// (#2501 D5-7) and a baseline note (#2688). Any new run clears it, so a later state never
// inherits an older verdict. baseline_accept is the retired #2517 grant: never written now,
// still cleared so a legacy state does not carry it past a new run. baseline_new_lines_seen
// (#2956 S9) is deliberately absent: the PR must still disclose new lines a later run hides.
const RUN_TOMBSTONES = {
  baseline_classification: null,
  completion_basis: null,
  unrunnable_accept_reason: null,
  baseline_accept: null,
  baseline_note: null,
};

// run_parts is written only by a settled run that computed it; otherwise left as it was.
function partsField(r) {
  return r.runParts === undefined ? {} : { run_parts: r.runParts };
}

// outcome_source names the outcome file a record came from (null on stdout);
// dispatch_unsettled names a dispatch whose outcome has not arrived yet.
function sourceFields(source, unsettledStem) {
  return { outcome_source: source || null, dispatch_unsettled: unsettledStem || null };
}

// hit_count is the contract's HITS (null when the contract is unreadable); hit_summary the bounded
// lines (#2669). The baseline CLI and the accept handler read both.
function hitFields(r) {
  return { hit_count: r.hitCount, hit_summary: r.hitCount === null ? null : r.hitSummary };
}

function recordFailedExit(r) {
  markStep(r.sessionId, "run_tests", "pending", {
    last_run_failed: true,
    last_exit_code: r.exitCode,
    trigger_command: r.triggerCommand,
    run_outcome: r.runOutcome,
    failing_tests: r.failingTests,
    failing_test_exits: r.failingExits,
    unrunnable_count: r.unrunnableCount,
    unrunnable_runtimes: null,
    unrunnable_missing_files: null,
    ...hitFields(r),
    ...RUN_TOMBSTONES,
    ...partsField(r),
    ...sourceFields(r.source, r.unsettledStem),
  });
  // #2430: a red suite outside the red-expected steps is a handoff risk. Never throws.
  if (r.stampRisk) stampTestFailureRisk(r.sessionId);
  return null;
}

// Returns the diagnostic { head, detail }; nothing reads it back as a judgement input.
// Exit 77 is "nothing passed" (all skipped or unrunnable), not a failure, so it demotes here.
function recordDemotion(r) {
  markStep(r.sessionId, "run_tests", "pending", {
    last_run_failed: false,
    ...(r.exitCode === 77 ? { last_exit_code: 77 } : {}),
    contract_absent: r.contractAbsent,
    trigger_command: r.triggerCommand,
    run_outcome: r.runOutcome,
    failing_tests: r.failingTests,
    failing_test_exits: r.failingExits === undefined ? null : r.failingExits,
    unrunnable_count: r.unrunnableCount,
    unrunnable_runtimes: r.reason === "contract-unrunnable" ? r.unrunnableRuntimes : null,
    unrunnable_missing_files: r.reason === "contract-unrunnable" ? r.unrunnableMissingFiles : null,
    ...hitFields(r),
    ...RUN_TOMBSTONES,
    ...partsField(r),
    ...sourceFields(r.source, r.unsettledStem),
  });
  return demotionMessage(r.reason, r.contract);
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
    failing_test_exits: null,
    unrunnable_count: null,
    unrunnable_runtimes: null,
    unrunnable_missing_files: null,
    hit_count: null,
    hit_summary: null,
    ...RUN_TOMBSTONES,
    ...partsField(r),
    ...sourceFields(r.source, null),
  }, { origin: "workflow-run-tests-auto-detect" });
  return null;
}

// A dispatch is in flight: no earlier result may stand for it until its outcome lands.
function recordUnsettled({ sessionId, stem, triggerCommand }) {
  return recordDemotion({
    sessionId,
    exitCode: null,
    contract: null,
    contractAbsent: null,
    triggerCommand,
    runOutcome: null,
    failingTests: null,
    unrunnableCount: null,
    unrunnableRuntimes: null,
    unrunnableMissingFiles: null,
    hitCount: null,
    hitSummary: null,
    source: null,
    unsettledStem: stem,
    reason: "dispatch-unsettled",
  });
}

// Only a current-shape contract can say how many selected tests never ran: a legacy one
// counted a missing runtime as SKIP. bin/run-tests-baseline reads the count.
function unrunnableCountOf(input, contract) {
  const readable = input.ambiguous !== true && input.attributed === true && contract !== null;
  return readable && contract.shape === "current" ? contract.unrunnable : null;
}

function hitCountOf(input, contract) {
  const readable = input.ambiguous !== true && input.attributed === true && contract !== null;
  if (!readable) return null;
  return Number.isInteger(contract.hits) ? contract.hits : 0;
}

// Green needs a trusted current-shape contract with no failure, no unrunnable test and no hit.
function isGreen(input, contract) {
  return isContractTrusted(input) && contract.shape === "current"
    && contract.fail === 0 && contract.unrunnable === 0 && !(contract.hits > 0);
}

// Adds this run to run_parts and, when it merges with earlier parts, replaces the run's own
// failing / hit / unrunnable values with the merged ones. -> true when the merge is not clean.
function applyRunParts(base, part, input) {
  if (base.contract === null) return false;
  const c = base.contract;
  // A readable current-shape contract; a worker's failure word vetoes green, not the counts.
  const trusted = base.hitCount !== null && c.shape === "current" && input.workerStatus !== "timeout";
  try {
    const { runParts, merged } = recordParts({
      sessionId: base.sessionId,
      part,
      run: {
        trusted,
        contract: c,
        failing: trusted && c.fail === 0 ? [] : base.failingTests,
        exits: base.failingExits,
        hitCount: base.hitCount,
        hitSummary: base.hitSummary,
        unrunnable: base.unrunnableCount,
      },
    });
    base.runParts = runParts;
    if (merged === null) return false;
    Object.assign(base, merged);
    return merged.failingTests.length > 0 || merged.hitCount > 0 || merged.unrunnableCount > 0;
  } catch {
    return false; // fail-open: the run is recorded alone, run_parts untouched
  }
}

// -> the { head, detail } diagnostic to surface, or null. `unsettledStem` blocks completion:
// while a dispatch is unsettled a run may take run_tests away, never grant it,
// and records no observation that could stand for that dispatch.
function recordRun(r) {
  const input = r.outcomeInput || {};
  const contract = input.contract === undefined ? null : input.contract;
  const unsettledStem = r.unsettledStem || null;
  const settled = unsettledStem === null;
  const base = {
    sessionId: r.sessionId,
    exitCode: r.exitCode,
    contract,
    triggerCommand: r.triggerCommand,
    runOutcome: settled ? resolveRunOutcome(input) : null,
    failingTests: settled && r.failingTests !== undefined ? r.failingTests : null,
    unrunnableCount: settled ? unrunnableCountOf(input, contract) : null,
    unrunnableRuntimes: r.unrunnableRuntimes === undefined ? null : r.unrunnableRuntimes,
    unrunnableMissingFiles: r.unrunnableMissingFiles === undefined ? null : r.unrunnableMissingFiles,
    hitCount: settled ? hitCountOf(input, contract) : null,
    hitSummary: boundHits(r.hitSummary),
    source: r.source || null,
    unsettledStem,
    stampRisk: r.stampRisk === true,
    contractAbsent: r.contractAbsent === undefined ? contract === null : r.contractAbsent,
  };
  base.failingExits = base.failingTests !== null && r.failingExits ? r.failingExits : null;
  const open = settled && r.part ? applyRunParts(base, r.part, input) : false;
  if (r.exitCode !== 0 && r.exitCode !== 77) return recordFailedExit(base);
  if (!settled) return recordDemotion(Object.assign(base, { reason: "dispatch-unsettled" }));
  if (r.exitCode === 0 && isGreen(input, contract) && open) {
    return recordDemotion(Object.assign(base, { reason: "run-parts-open" }));
  }
  if (r.exitCode !== 0 || !isGreen(input, contract)) {
    const reason = r.reason || demotionReason({
      hasProvenance: true,
      ambiguous: input.ambiguous === true,
      attributed: input.attributed === true,
      contract,
      contractMiss: null,
      vetoed: input.vetoed === true,
      workerStatus: input.workerStatus === undefined ? null : input.workerStatus,
    });
    return recordDemotion(Object.assign(base, { reason }));
  }
  return recordPass(base);
}

module.exports = { RUN_TOMBSTONES, recordRun, recordUnsettled };
