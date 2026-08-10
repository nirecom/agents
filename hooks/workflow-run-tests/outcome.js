"use strict";
// The run_tests OUTCOME axis (#1665 commit 2).
//
// WHY (CPR-WPH): `run_tests` has always carried exactly one axis — a STATUS
// (complete / pending) that answers "may the workflow move on?". It never
// recorded the orthogonal fact "what did the run itself report?", so a failing
// run and a run that was never trusted are indistinguishable downstream, and the
// write_code resume cascade has nothing to trigger on. This module owns that
// second axis and nothing else (CPR-SC): it decides a VALUE, it never writes.
//
// Two rules shape every signature here.
//
//   1. VOCABULARY IS BORROWED, NOT INVENTED. The outcome domain is exactly
//      bin/worker-dispatch/emit.js's renderer vocabulary — pass | fail | timeout
//      | runner-error. A synonym introduced here would be a second spelling of a
//      fact the renderer already names (CPR-SSOT).
//
//   2. NO RAW STDOUT CROSSES THIS BOUNDARY. Every entry point takes either
//      already-computed judgements or the `log_tail`-stripped HEADER — never the
//      whole stdout of a Bash call. bin/worker-dispatch/emit.js hard-indents the
//      block scalar with bytes the SUITE chose, so a `status:` or `RUN_CONTRACT:`
//      line found there is log text, not a verdict. Keeping stdout out of the
//      signature makes "I accidentally passed the log tail" unrepresentable
//      rather than merely discouraged (detail plan risk (i)).

// The whole outcome domain. Order matches emit.js's documented vocabulary.
const RUN_OUTCOME_VALUES = ["pass", "fail", "timeout", "runner-error"];

// The single sanctioned green word. ALLOWLIST, not denylist (#1273 round 3 /
// NEW-L2): "not a known failure" is not the same claim as "the worker said it
// passed", so a renamed word, a typo (`passed`) or a value clipped by emit.js's
// 64-char plainValue cap must all read as NOT-pass.
const WORKER_PASS_STATUS = "pass";

// The worker's own failure words — the outcome domain minus the green one. These
// are the only values the worker route may contribute VERBATIM.
const WORKER_FAILURE_STATUSES = RUN_OUTCOME_VALUES.filter((v) => v !== WORKER_PASS_STATUS);

// --- the worker's verdict fields (R7: ONE parse site) -----------------------
//
// Both consumers of the `status:` / `exit_code:` lines go through here: the veto
// (does this payload forbid a completion?) and the outcome (what did it report?).
// A second regex next to the first would drift on the first tweak — someone
// tolerates a trailing comment, or stops lowercasing, in one site only — and the
// hook could then veto a completion while recording "pass".
//
// Line-anchored on purpose: `^` with /m, no leading-whitespace tolerance. An
// indented `  status: pass` is block-scalar text even if a caller hands it in.
const STATUS_LINE_RE = /^status:[ \t]*(\S+)/m;
const EXIT_CODE_LINE_RE = /^exit_code:[ \t]*(-?\d+)/m;

// parseWorkerVerdict(header) -> { status, exitCode }
// `status` is the token VERBATIM, lowercased — this site reports, it does not
// judge; the allowlist decision belongs to the caller. `header` must already be
// log_tail-stripped.
//
// The two lines are ONE verdict record, so `exit_code:` is only read when an
// anchored `status:` line established that a verdict header is present at all.
// Otherwise an indented `  status: pass` (block-scalar text the suite chose)
// sitting above an unrelated unindented `exit_code: 0` would contribute half a
// verdict, and half a verdict is the shape a forger needs.
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

// --- the trust condition (R3: ONE definition site) --------------------------
//
// Six conjuncts, all of which must hold before a RUN_CONTRACT line may be read
// as this run's report of itself:
//
//   !ambiguous        two distinct authorised emitters in one command — nothing
//                     is attributable to either (#1273 round 4 / NEW-N1)
//   attributed        the bytes are positionally the emitter's own (#1273 H1)
//   !vetoed           the worker process did not contradict the contract (#1242 C')
//   contract !== null present and unambiguous (the exactly-one rule)
//   executed > 0      the run matched something
//   pass + fail > 0   not an all-SKIP run
//
// `fail === 0` is deliberately NOT a conjunct. This predicate answers "may I
// believe this contract?", not "did the run pass" — folding the verdict in would
// make a trustworthy FAIL>0 report indistinguishable from an untrustworthy one,
// which is exactly the C1 primary path (tests/run-all.sh prints a valid contract
// and THEN exits 1). Callers that need the old seven-term meaning derive it as
// `isContractTrusted(x) && x.contract.fail === 0`.
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

// --- the decision table -----------------------------------------------------
//
// resolveRunOutcome(input) -> one of RUN_OUTCOME_VALUES, or null.
//
// input: { emitter, ambiguous, attributed, vetoed, contract, workerStatus }
//   — all precomputed by the caller; see rule 2 in the header comment.
//
//   1. worker route, unambiguous, attributed, and the worker named a failure
//      word  -> that word, verbatim. The process that ran the suite outranks a
//      contract computed from its stdout: a suite that died after printing its
//      summary produces a green contract and a red process.
//   2. trusted contract with FAIL > 0 -> "fail"  (the C1 primary path)
//   3. trusted contract with FAIL == 0 -> "pass"
//   4. anything else -> null
//
// null is NOT "the run failed". It is "no trustworthy observation exists", and
// the writer treats it as a TOMBSTONE that clears any prior annotation — a stale
// outcome surviving an unobservable run would keep the resume cascade firing on
// evidence that no longer exists.
//
// Note the asymmetry in row 1: `status: pass` is not a row-1 value. A worker that
// claims pass while its contract is untrustworthy is two trusted renderings
// disagreeing, which is an attribution failure, not a verdict.
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
