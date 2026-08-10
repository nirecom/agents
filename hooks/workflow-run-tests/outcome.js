"use strict";
// The run_tests OUTCOME axis: complements the existing STATUS axis
// (complete/pending — "may the workflow move on?") with the orthogonal fact
// "what did the run itself report?", so a failing run and a run that was never
// trusted are distinguishable, and the write_code resume cascade has something
// to trigger on. This module decides a VALUE; it never writes state.
//
// The vocabulary (pass/fail/timeout/runner-error) is borrowed verbatim from
// bin/worker-dispatch/emit.js's renderer — never invent a synonym here.
//
// No raw stdout crosses this boundary: every entry point takes either
// already-computed judgements or the `log_tail`-stripped HEADER, never the
// whole stdout of a Bash call — a `status:`/`RUN_CONTRACT:` line inside the
// worker's block-scalar log text is log text, not a verdict.

const RUN_OUTCOME_VALUES = ["pass", "fail", "timeout", "runner-error"];

// Allowlist, not denylist: "not a known failure" is not the same claim as "the
// worker said it passed", so a renamed word, a typo, or a value clipped by
// emit.js's plainValue cap must all read as NOT-pass.
const WORKER_PASS_STATUS = "pass";

const WORKER_FAILURE_STATUSES = RUN_OUTCOME_VALUES.filter((v) => v !== WORKER_PASS_STATUS);

// One parse site for both the veto check and the outcome check — a second
// regex next to this one would drift and let the hook veto a completion while
// recording "pass". Line-anchored (`^` with /m): an indented `  status: pass`
// is block-scalar text, not a verdict line, even if a caller hands it in.
const STATUS_LINE_RE = /^status:[ \t]*(\S+)/m;
const EXIT_CODE_LINE_RE = /^exit_code:[ \t]*(-?\d+)/m;

// parseWorkerVerdict(header) -> { status, exitCode }. `status` is returned
// verbatim/lowercased — this reports, it doesn't judge. `exit_code` is only
// read once an anchored `status:` line proves a verdict header is present;
// otherwise an unrelated stray `exit_code:` line could contribute half a
// verdict.
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

// The trust condition — every conjunct must hold before a RUN_CONTRACT line may
// be read as this run's report of itself: unambiguous emitter, attributed
// bytes, not vetoed by the process, a present contract, and a non-empty,
// non-all-skip run. `fail === 0` is deliberately NOT a conjunct — this answers
// "may I believe this contract?", not "did the run pass"; a trustworthy
// FAIL>0 report (suite prints a valid contract, then exits 1) must stay
// distinguishable from an untrustworthy one. Callers wanting the old
// pass-or-fail meaning derive it as `isContractTrusted(x) && x.contract.fail === 0`.
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

// resolveRunOutcome(input) -> one of RUN_OUTCOME_VALUES, or null.
// input: { emitter, ambiguous, attributed, vetoed, contract, workerStatus } —
// all precomputed by the caller.
//
// Decision order: an unambiguous, attributed worker-route failure word wins
// verbatim (the process that ran the suite outranks a contract computed from
// its own stdout — a suite that died after printing its summary produces a
// green contract and a red process); otherwise a trusted contract decides
// pass/fail by its fail count; otherwise null.
//
// `status: pass` is deliberately not a winning case in row 1 — a worker
// claiming pass while its contract is untrustworthy is two renderings
// disagreeing, not a verdict. null means "no trustworthy observation exists"
// (not "the run failed"), and the writer treats it as a tombstone clearing any
// prior annotation, since a stale outcome would keep the resume cascade firing
// on evidence that no longer exists.
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
  isContractTrusted,
  resolveRunOutcome,
};
