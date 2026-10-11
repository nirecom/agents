"use strict";
// run-tests-baseline-evidence.js — the state side of bin/run-tests-baseline (#2431).
// `failing` hands the hook-recorded failing list to the CLI; `record` completes
// run_tests only when every failing path was classified as pre-existing at the
// merge base. The check and the write share ONE appendEvents builder so no other
// run or reset can slip in between (observed evidence, Class O; not markStep).

const fs = require("fs");
const path = require("path");

const STATE_IO = path.join(__dirname, "..", "..", "..", "hooks", "workflow-state", "state-io");
const ORIGIN = "run-tests-baseline-evidence";
const FAILING_OUTCOMES = ["fail", "timeout", "runner-error"];
const PREEXISTING_CLASSES = ["preexisting", "preexisting-inherited"];
const VALID_CLASSES = PREEXISTING_CLASSES.concat(["broken", "undetermined"]);

// Exit codes: 0 completed / listed, 1 classification does not authorize
// completion, 2 usage error, 3 state is not in the expected shape (or moved).
const EXIT = { OK: 0, UNMET: 1, USAGE: 2, STATE: 3 };

function stateIo() {
  return require(STATE_IO);
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
  if (!Array.isArray(ft) || ft.length === 0) return "failing_tests is not a non-empty list";
  if (!ft.every((p) => typeof p === "string" && p !== "")) return "failing_tests holds a non-path entry";
  return null;
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
  const why = failingPrecondition(entry) || dispatchPrecondition(sessionId, entry);
  if (why !== null) return { code: EXIT.STATE, stderr: why };
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
};
