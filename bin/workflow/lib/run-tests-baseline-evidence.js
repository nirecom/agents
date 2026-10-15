"use strict";
// run-tests-baseline-evidence.js — the state side of bin/run-tests-baseline (#2431).
// `failing` hands the hook-recorded failing list to the CLI; `record` completes
// run_tests only when every failing path was classified as pre-existing at the
// merge base; `accept` completes it on the user's grant (#2517). Each check and its
// write share ONE appendEvents builder so no other run or reset can slip in between
// (observed evidence, Class O; not markStep).

const fs = require("fs");
const path = require("path");

const STATE_IO = path.join(__dirname, "..", "..", "..", "hooks", "workflow-state", "state-io");
const ORIGIN = "run-tests-baseline-evidence";
// "unrunnable" is excluded: a missing runtime is fixed by installing it, never by a baseline.
const FAILING_OUTCOMES = ["fail", "timeout", "runner-error"];
const PREEXISTING_CLASSES = ["preexisting", "preexisting-inherited"];
const VALID_CLASSES = PREEXISTING_CLASSES.concat(["broken", "undetermined"]);
const NO_LIST = "failing_tests is not a non-empty list";

// Exit codes: 0 completed / listed, 1 classification does not authorize
// completion, 2 usage error, 3 state is not in the expected shape (or moved),
// 6 `accept` found no user grant (baseline_accept) to act on.
const EXIT = { OK: 0, UNMET: 1, USAGE: 2, STATE: 3, ABSENT: 6 };

function stateIo() {
  return require(STATE_IO);
}

function acceptForm() {
  return require(path.join(__dirname, "..", "..", "..", "hooks", "workflow-run-tests", "demotion"))
    .BASELINE_ACCEPT_SENTINEL_FORM;
}

function acceptBasis() {
  return require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "run-tests-completion-note"))
    .BASELINE_ACCEPT_BASIS;
}

function hasPositiveUnrunnable(entry) {
  return Number.isInteger(entry.unrunnable_count) && entry.unrunnable_count > 0;
}

function runTestsEntry(steps) {
  return steps && typeof steps === "object" ? steps.run_tests || null : null;
}

// Why the entry cannot be baseline-classified, or null when it can.
function failingPrecondition(entry) {
  if (!entry) return "run_tests has no state entry";
  if (entry.status !== "pending") return `run_tests status is ${entry.status}, not pending`;
  if (!FAILING_OUTCOMES.includes(entry.run_outcome)) return "run_outcome is not a failing value";
  const ft = entry.failing_tests;
  if (!Array.isArray(ft) || ft.length === 0) return NO_LIST;
  if (!ft.every((p) => typeof p === "string" && p !== "")) return "failing_tests holds a non-path entry";
  return null;
}

// A list-less failing run is grantable (kind failing-list-unrecorded): `failing` names the sentinel.
function isListless(entry) {
  const ft = entry.failing_tests;
  return ft === null || ft === undefined || (Array.isArray(ft) && ft.length === 0);
}

function listlessHint(sessionId, entry, pre) {
  if (pre !== NO_LIST || entry.unrunnable_count !== 0 || !isListless(entry)) return "";
  if (dispatchPrecondition(sessionId, entry) !== null) return "";
  return `\nOnly if the user confirmed these failures are pre-existing, accept with ${acceptForm()}; ` +
    "with no failing list a broken test may be among them.";
}

function settlement() {
  return require(path.join(__dirname, "..", "..", "..", "hooks", "workflow-state", "dispatch-settlement"));
}

// #2544: the failing list may come from a dispatch outcome. It stands only while no
// newer test-runner dispatch is unsettled and the outcome it came from is unchanged.
function dispatchPrecondition(sessionId, entry) {
  const s = settlement();
  const { unsettled, reason } = s.listUnsettled({ sessionId });
  if (reason) return reason;
  if (unsettled.some((u) => u.worker === "test-runner")) return "a newer test-runner dispatch has not settled";
  const source = entry.outcome_source;
  if (source === null || source === undefined) return null;
  return s.outcomeSourceStatus({ sessionId, source }) === "match" ? null : "outcome source changed or missing";
}

function failing(sessionId) {
  let entry;
  try {
    const state = stateIo().readState(sessionId);
    entry = runTestsEntry(state && state.steps);
  } catch (e) {
    return { code: EXIT.STATE, stderr: `cannot read state: ${e.message}` };
  }
  const pre = failingPrecondition(entry);
  const why = pre || dispatchPrecondition(sessionId, entry);
  if (why !== null) return { code: EXIT.STATE, stderr: why + listlessHint(sessionId, entry, pre) };
  const seq = entry.updated_seq;
  if (!Number.isInteger(seq)) return { code: EXIT.STATE, stderr: "run_tests has no updated_seq" };
  return { code: EXIT.OK, stdout: [`SEQ=${seq}`].concat(entry.failing_tests).join("\n") + "\n" };
}

// `<rel-path>\t<class>\t<detail>` per line; blank lines ignored, bad lines are errors.
function parseClassification(text) {
  const entries = [];
  for (const raw of String(text).replace(/\r\n/g, "\n").split("\n")) {
    if (raw.trim() === "") continue;
    const [p, cls, ...rest] = raw.split("\t");
    if (!p || !VALID_CLASSES.includes(cls)) throw new Error("malformed classification line");
    entries.push({ path: p, class: cls, detail: rest.join("\t") });
  }
  return entries;
}

// Set cover by path identity: duplicates never stand in for an omitted path.
function coverStatus(failingTests, entries) {
  const want = new Set(failingTests);
  const have = new Set(entries.map((e) => e.path));
  const missing = [...want].filter((p) => !have.has(p));
  const foreign = [...have].filter((p) => !want.has(p));
  return { covered: missing.length === 0 && foreign.length === 0, missing, foreign };
}

function annotation(key, value) {
  return { kind: "step_annotation", step: "run_tests", key, value, provenance: "observed", origin: ORIGIN };
}

function record(sessionId, seq, entries, base) {
  const verdict = { code: EXIT.STATE, reason: "state was not examined" };
  stateIo().appendEvents(sessionId, (_events, current) => {
    const entry = runTestsEntry(current && current.steps);
    if (!entry || entry.updated_seq !== seq) {
      verdict.reason = "run_tests changed since `failing` was read (seq mismatch)";
      return [];
    }
    const why = failingPrecondition(entry) || dispatchPrecondition(sessionId, entry);
    if (why !== null) {
      verdict.reason = why;
      return [];
    }
    const classification = annotation("baseline_classification", { base: base || null, entries });
    const cover = coverStatus(entry.failing_tests, entries);
    if (!cover.covered) {
      verdict.code = EXIT.UNMET;
      verdict.reason = `classification does not cover failing_tests (missing=${cover.missing.length}, foreign=${cover.foreign.length})`;
      return [classification];
    }
    const notPre = entries.filter((e) => !PREEXISTING_CLASSES.includes(e.class));
    if (notPre.length > 0) {
      verdict.code = EXIT.UNMET;
      verdict.reason = `${notPre.length} failing test(s) are not pre-existing at the merge base`;
      if (notPre.every((e) => e.class === "undetermined") && entry.unrunnable_count === 0) {
        verdict.reason += `\nOnly if the user confirmed the undetermined tests are pre-existing, accept with ${acceptForm()} ` +
          "and re-run bin/run-tests-baseline.";
      }
      return [classification];
    }
    // A selected test that never ran (UNRUNNABLE) proves nothing about itself, so the step stays
    // pending however the failures classify; only the hook's own exact 0 clears this.
    if (entry.unrunnable_count !== 0) {
      verdict.code = EXIT.UNMET;
      verdict.reason = Number.isInteger(entry.unrunnable_count)
        ? `${entry.unrunnable_count} selected test(s) were UNRUNNABLE; install the missing runtime and re-run /run-tests`
        : "the failing run recorded no unrunnable_count; re-run /run-tests";
      return [classification];
    }
    verdict.code = EXIT.OK;
    verdict.reason = null;
    // run_outcome "pass": a failing value would make write-code-resume reopen
    // write_code; the real nature of this completion lives in completion_basis.
    return [
      classification,
      annotation("run_outcome", "pass"),
      annotation("completion_basis", "baseline-preexisting"),
      { kind: "step_status", step: "run_tests", status: "complete", provenance: "observed", origin: ORIGIN },
    ];
  });
  return verdict;
}

// The grant kind the entry supports now, or null. The sentinel handler judges with this same function.
// Only the hook's own exact 0 unrunnable count is grantable: null, absent or malformed proves nothing.
function grantKind(entry) {
  if (!entry || entry.unrunnable_count !== 0) return null;
  const pre = failingPrecondition(entry);
  if (pre === NO_LIST && isListless(entry)) return "failing-list-unrecorded";
  if (pre !== null) return null;
  const cls = entry.baseline_classification;
  if (!cls || !Array.isArray(cls.entries)) return null;
  if (!coverStatus(entry.failing_tests, cls.entries).covered) return null;
  const notPre = cls.entries.filter((e) => !PREEXISTING_CLASSES.includes(e.class));
  if (notPre.length === 0 || !notPre.every((e) => e.class === "undetermined")) return null;
  return "undetermined";
}

function sameSource(a, b) {
  const none = (s) => s === null || s === undefined;
  if (none(a) || none(b)) return none(a) && none(b);
  return a.stem === b.stem && a.outcome_sha256 === b.outcome_sha256;
}

// Why the grant cannot complete `entry`: { code, reason }, or null when it can (#2517 Steps 4).
function acceptRefusal(sessionId, entry, grant) {
  const unmet = (reason) => ({ code: EXIT.UNMET, reason });
  if (grant.run_seq !== entry.updated_seq) return unmet("run_tests changed after the grant; accept again");
  if (!sameSource(grant.outcome_source, entry.outcome_source)) {
    return unmet("the outcome behind the run changed after the grant; accept again");
  }
  if (entry.status !== "pending" || !FAILING_OUTCOMES.includes(entry.run_outcome)) {
    return { code: EXIT.STATE, reason: `run_tests is ${entry.status} with run_outcome=${entry.run_outcome}, not a pending failing run` };
  }
  if (entry.run_outcome !== grant.accepted_run_outcome) return unmet("run_outcome changed after the grant; accept again");
  const dispatchWhy = dispatchPrecondition(sessionId, entry);
  if (dispatchWhy !== null) return { code: EXIT.STATE, reason: dispatchWhy };
  if (hasPositiveUnrunnable(entry)) {
    return unmet(`${entry.unrunnable_count} selected test(s) were UNRUNNABLE; use the UNRUNNABLE_ACCEPTED path instead`);
  }
  if (entry.unrunnable_count !== 0) return unmet("the failing run recorded no exact unrunnable_count of 0; re-run /run-tests");
  const kind = grantKind(entry);
  if (kind === null || kind !== grant.kind) {
    return unmet(`the run no longer supports the grant (state kind=${kind || "none"}, grant kind=${grant.kind})`);
  }
  return null;
}

// Completes run_tests on the user's grant. The grant is never rewritten: it keeps the kind,
// the reason and the accepted run_outcome for the disclosure (CPR-SSOT).
function accept(sessionId) {
  const verdict = { code: EXIT.STATE, reason: "state was not examined", kind: null };
  stateIo().appendEvents(sessionId, (_events, current) => {
    const entry = runTestsEntry(current && current.steps);
    const grant = entry && entry.baseline_accept;
    if (!grant || typeof grant !== "object") {
      verdict.code = EXIT.ABSENT;
      verdict.reason = null;
      return [];
    }
    const refusal = acceptRefusal(sessionId, entry, grant);
    if (refusal !== null) {
      Object.assign(verdict, refusal);
      return [];
    }
    Object.assign(verdict, { code: EXIT.OK, reason: null, kind: grant.kind });
    return [
      annotation("run_outcome", "pass"),
      annotation("completion_basis", acceptBasis()),
      { kind: "step_status", step: "run_tests", status: "complete", provenance: "observed", origin: ORIGIN },
    ];
  });
  return verdict;
}

function recordFromFile(sessionId, seq, file, base) {
  let entries;
  try {
    entries = parseClassification(fs.readFileSync(file, "utf8"));
  } catch (e) {
    return { code: EXIT.USAGE, reason: `cannot read classification: ${e.message}` };
  }
  try {
    return record(sessionId, seq, entries, base);
  } catch (e) {
    return { code: EXIT.STATE, reason: `state write failed: ${e.message}` };
  }
}

module.exports = {
  EXIT,
  ORIGIN,
  failing,
  parseClassification,
  coverStatus,
  record,
  recordFromFile,
  accept,
  grantKind,
};
