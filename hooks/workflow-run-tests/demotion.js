"use strict";
// Why a run_tests demotion happened, and the one human-facing message per reason. Diagnostics
// only: no code path reads the reason or the message back (workflow-run-tests.js done()).
// The message is the same on both routes, so the reader's next action never depends on which
// emitter ran the suite. Contract shapes: hooks/lib/run-contract.js.

const UNRUNNABLE_ACCEPT_SENTINEL_FORM = "echo \"<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>\"";
// Not used in demotion messages: a failing run never demotes; the baseline evidence CLI guides it.
const BASELINE_ACCEPT_SENTINEL_FORM = "echo \"<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: {reason}>>\"";

// The run's only defect is a missing runtime: a current-shape contract with no failure, and
// either no veto or the worker's own `unrunnable` word (the pass-only allowlist vetoes it too).
function isUnrunnableOnly(contract, vetoed, workerStatus) {
  return contract !== null && contract.shape === "current" && contract.fail === 0
    && contract.unrunnable > 0 && (!vetoed || workerStatus === "unrunnable");
}

// A 4-field contract with no failure cannot prove UNRUNNABLE=0 (#2501 C3); the worker's
// `skip` word is vetoed by the same allowlist, and the rebase guidance must still win.
function isLegacyGreen(contract, vetoed, workerStatus) {
  return contract !== null && contract.shape === "legacy" && contract.fail === 0
    && (!vetoed || workerStatus === "skip");
}

// demotionReason(t) — t: { hasProvenance, ambiguous, attributed, contract, contractMiss,
// vetoed, workerStatus }; contractMiss is findSingleContract's {reason} when contract is null.
function demotionReason(t) {
  if (!t.hasProvenance) return "provenance-absent";
  if (t.ambiguous) return "provenance-ambiguous";
  if (!t.attributed) return "stdout-unattributed";
  if (isUnrunnableOnly(t.contract, t.vetoed, t.workerStatus)) return "contract-unrunnable";
  if (isLegacyGreen(t.contract, t.vetoed, t.workerStatus)) return "contract-legacy-shape";
  if (t.vetoed) return "worker-status-veto";
  if (t.contract !== null) return "contract-invalid";
  return t.contractMiss && t.contractMiss.reason === "ambiguous" ? "contract-ambiguous" : "contract-absent";
}

function demotionMessage(reason, contract) {
  const head = `run_tests demoted to pending (${reason}). `;
  if (reason === "contract-unrunnable") {
    return head + `Selected tests marked UNRUNNABLE: ${contract.unrunnable}. ` +
      "Install the runtimes listed on the `Missing runtimes:` output line and run again. " +
      `If a runtime cannot be installed, accept this run only with ${UNRUNNABLE_ACCEPT_SENTINEL_FORM}.`;
  }
  if (reason === "contract-legacy-shape") {
    return head + "RUN_CONTRACT has the legacy 4-field form: the worktree's tests/run-all.sh predates this change, " +
      "so rebase onto main and run again.";
  }
  return head + "Completion requires tests/run-all.sh (or the worker-dispatch test-runner) " +
    "and exactly one valid RUN_CONTRACT line in its output.";
}

module.exports = {
  demotionReason, demotionMessage, isUnrunnableOnly,
  UNRUNNABLE_ACCEPT_SENTINEL_FORM, BASELINE_ACCEPT_SENTINEL_FORM,
};
