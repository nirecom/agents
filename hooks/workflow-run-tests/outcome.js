"use strict";
// The run_tests OUTCOME axis (pass/fail/timeout/runner-error, emit.js's renderer
// vocabulary): "what did the run report?", orthogonal to the complete/pending
// STATUS axis. Decides a value, never writes state, and never reads raw stdout —
// callers hand in judgements or the `log_tail`-stripped header.
// Trust model: docs/architecture/claude-code/settings/hooks.md.

const RUN_OUTCOME_VALUES = ["pass", "fail", "timeout", "runner-error"];

// Allowlist: a renamed word, a typo, or a value clipped by emit.js reads as NOT-pass.
const WORKER_PASS_STATUS = "pass";

const WORKER_FAILURE_STATUSES = RUN_OUTCOME_VALUES.filter((v) => v !== WORKER_PASS_STATUS);

// The single parse site for the veto and the outcome (R7). Line-anchored: an
// indented `  status: pass` is block-scalar text, not a verdict line.
const STATUS_LINE_RE = /^status:[ \t]*(\S+)/m;
const EXIT_CODE_LINE_RE = /^exit_code:[ \t]*(-?\d+)/m;

// -> { status, exitCode }; reports, never judges. exit_code is read only once an
// anchored status line proves a verdict header is present.
function parseWorkerVerdict(header) {
  const text = typeof header === "string" ? header : "";
  const sm = STATUS_LINE_RE.exec(text);
  if (sm === null) return { status: null, exitCode: null };
  const em = EXIT_CODE_LINE_RE.exec(text);
  return {
    status: sm[1].toLowerCase(),
    exitCode: em === null ? null : parseInt(em[1], 10),
  };
}

// The worker's own verdict vetoes a contract computed from its output: on the
// worker route the OS exit code is 0 by construction. Only `pass` with exit 0 (or
// no exit line) is green. Takes parseWorkerVerdict's fields or an outcome record's.
function workerVerdictVetoes(status, exitCode) {
  if (status !== WORKER_PASS_STATUS) return true;
  return exitCode !== null && exitCode !== undefined && exitCode !== 0;
}

// May this RUN_CONTRACT be believed as the run's report of itself? `fail === 0` is
// deliberately not a conjunct, so a trustworthy FAIL>0 report stays distinguishable.
function isContractTrusted(input) {
  const i = input || {};
  const c = i.contract;
  return i.ambiguous !== true
    && i.attributed === true
    && i.vetoed !== true
    && c !== null && c !== undefined
    && c.executed > 0
    && (c.pass + c.fail) > 0;
}

// -> one of RUN_OUTCOME_VALUES, or null (a tombstone: no trustworthy observation).
// An attributed worker failure word wins verbatim; else a trusted contract decides.
function resolveRunOutcome(input) {
  const i = input || {};
  if (
    i.emitter === "worker-dispatch"
    && i.ambiguous !== true
    && i.attributed === true
    && WORKER_FAILURE_STATUSES.indexOf(i.workerStatus) !== -1
  ) {
    return i.workerStatus;
  }
  if (isContractTrusted(i)) {
    return i.contract.fail > 0 ? "fail" : "pass";
  }
  return null;
}

module.exports = {
  RUN_OUTCOME_VALUES,
  WORKER_PASS_STATUS,
  WORKER_FAILURE_STATUSES,
  parseWorkerVerdict,
  workerVerdictVetoes,
  isContractTrusted,
  resolveRunOutcome,
};
