"use strict";
// run-tests-baseline-evidence.js — the state side of bin/run-tests-baseline (#2431).
// `failing` hands the hook-recorded failing list to the CLI; `record` completes
// run_tests when the classification passes the #2688 allow-list (disposition.js).
// Each check and its write share ONE appendEvents builder so no other run or reset
// can slip in between (observed evidence, Class O; not markStep).

const fs = require("fs");
const path = require("path");
const disposition = require(path.join(__dirname, "run-tests-baseline-evidence", "disposition"));

const STATE_IO = path.join(__dirname, "..", "..", "..", "hooks", "workflow-state", "state-io");
const ORIGIN = "run-tests-baseline-evidence";
// "unrunnable" is excluded: a missing runtime is fixed by installing it, never by a baseline.
const FAILING_OUTCOMES = ["fail", "timeout", "runner-error"];
const VALID_CLASSES = ["preexisting", "preexisting-inherited", "broken", "undetermined",
  "flaky-timeout-on-branch", "passes-alone-on-branch", "file-verdict-preexisting", "new-case-failure-on-branch"];
const NO_LIST = "failing_tests is not a non-empty list";

// Exit codes: 0 completed / listed, 1 classification does not authorize
// completion, 2 usage error, 3 state is not in the expected shape (or moved),
// 7 `failing` found a run with unattributed hits (#2669; the CLI reports it as its own exit 6),
// 8 the classification did not finish (budget, worktree, setup); re-run /run-tests.
const EXIT = { OK: 0, UNMET: 1, USAGE: 2, STATE: 3, HITS: 7, RERUN: 8 };
const HITS_WHY = "the run left unattributed hits (HITS>0); no failure in it can be classified";

function stateIo() {
  return require(STATE_IO);
}

function runTestsEntry(steps) {
  return steps && typeof steps === "object" ? steps.run_tests || null : null;
}

// The recorded hit_count when it is a positive integer, else 0.
function hitCount(entry) {
  const n = entry ? entry.hit_count : undefined;
  return Number.isInteger(n) && n > 0 ? n : 0;
}

// Why the entry cannot be baseline-classified, or null when it can.
function failingPrecondition(entry) {
  if (!entry) return "run_tests has no state entry";
  if (entry.status !== "pending") return `run_tests status is ${entry.status}, not pending`;
  if (hitCount(entry) > 0) return HITS_WHY;
  if (!FAILING_OUTCOMES.includes(entry.run_outcome)) return "run_outcome is not a failing value";
  const ft = entry.failing_tests;
  if (!Array.isArray(ft) || ft.length === 0) return NO_LIST;
  if (!ft.every((p) => typeof p === "string" && p !== "")) return "failing_tests holds a non-path entry";
  return null;
}

function isListless(entry) {
  const ft = entry.failing_tests;
  return ft === null || ft === undefined || (Array.isArray(ft) && ft.length === 0);
}

// A list-less failing run names no test to classify; only a fresh run can record the list.
function listlessHint(entry, pre) {
  if (pre !== NO_LIST || !isListless(entry)) return "";
  return "\nRe-run /run-tests so the failing tests are recorded, then run bin/run-tests-baseline again.";
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
  if (pre === HITS_WHY) {
    const summary = Array.isArray(entry.hit_summary) ? entry.hit_summary.filter((h) => typeof h === "string") : [];
    return { code: EXIT.HITS, stdout: [`HIT_COUNT=${hitCount(entry)}`].concat(summary).join("\n") + "\n" };
  }
  const why = pre || dispatchPrecondition(sessionId, entry);
  if (why !== null) return { code: EXIT.STATE, stderr: why + listlessHint(entry, pre) };
  const seq = entry.updated_seq;
  if (!Number.isInteger(seq)) return { code: EXIT.STATE, stderr: "run_tests has no updated_seq" };
  return { code: EXIT.OK, stdout: [`SEQ=${seq}`].concat(entry.failing_tests, exitLines(entry)).join("\n") + "\n" };
}

// `EXIT\t<code>\t<path>` for each failing path whose own exit was recorded (#2688 branch stage).
function exitLines(entry) {
  const exits = entry.failing_test_exits;
  if (!exits || typeof exits !== "object" || Array.isArray(exits)) return [];
  return entry.failing_tests
    .filter((p) => Number.isInteger(exits[p]) && exits[p] >= 0)
    .map((p) => `EXIT\t${exits[p]}\t${p}`);
}

// The 5th column: a JSON array of strings (the comparer's first new lines).
function parseHead(text) {
  let head;
  try {
    head = JSON.parse(text);
  } catch {
    throw new Error("malformed classification line (new-lines head is not JSON)");
  }
  if (!Array.isArray(head) || !head.every((l) => typeof l === "string")) {
    throw new Error("malformed classification line (new-lines head is not a string list)");
  }
  return head;
}

// `<rel-path>\t<class>\t<detail>\t<new-count>\t<new-head-json>` per line (#2956 S8);
// blank lines ignored, bad lines (the pre-#2956 3-column form included) are errors.
function parseClassification(text) {
  const entries = [];
  for (const raw of String(text).replace(/\r\n/g, "\n").split("\n")) {
    if (raw.trim() === "") continue;
    const cols = raw.split("\t");
    const [p, cls, detail, count, head] = cols;
    if (cols.length !== 5 || !p || !VALID_CLASSES.includes(cls)) throw new Error("malformed classification line");
    if (!/^(0|[1-9][0-9]*)$/.test(count)) throw new Error("malformed classification line (new-lines count)");
    entries.push({ path: p, class: cls, detail, new_lines: { count: Number(count), head: parseHead(head) } });
  }
  return entries;
}

// baseline_new_lines_seen: the prior value plus this record's rows with new lines, per path.
// Not a RUN_TOMBSTONE, so a later run or a green completion still discloses it (#2956 S9).
function newLinesSeen(entry, entries) {
  const add = {};
  for (const e of entries) {
    if (!e.new_lines || e.new_lines.count <= 0) continue;
    add[e.path] = { count: e.new_lines.count, head: e.new_lines.head, class: e.class, detail: e.detail };
  }
  if (Object.keys(add).length === 0) return [];
  const prior = entry.baseline_new_lines_seen;
  const base = prior && typeof prior === "object" && !Array.isArray(prior) ? prior : {};
  return [annotation("baseline_new_lines_seen", Object.assign({}, base, add))];
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

function record(sessionId, seq, entries, base, note) {
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
    const classification = [annotation("baseline_classification", { base: base || null, entries })]
      .concat(newLinesSeen(entry, entries));
    const cover = coverStatus(entry.failing_tests, entries);
    if (!cover.covered) {
      verdict.code = EXIT.UNMET;
      verdict.reason = `classification does not cover failing_tests (missing=${cover.missing.length}, foreign=${cover.foreign.length})`;
      return classification;
    }
    const agg = disposition.aggregate(entries);
    if (agg.verdict === "pending") {
      verdict.code = EXIT.UNMET;
      verdict.reason = `${agg.count} failing test(s) are neither pre-existing at the merge base nor an auto-accepted cause`;
      return classification;
    }
    if (agg.verdict === "rerun") {
      verdict.code = EXIT.RERUN;
      verdict.reason = `${agg.count} failing test(s) could not be classified this time; re-run /run-tests, then bin/run-tests-baseline`;
      return classification;
    }
    // A selected test that never ran (UNRUNNABLE) proves nothing about itself, so the step stays
    // pending however the failures classify; only the hook's own exact 0 clears this.
    if (entry.unrunnable_count !== 0) {
      verdict.code = EXIT.UNMET;
      verdict.reason = Number.isInteger(entry.unrunnable_count)
        ? `${entry.unrunnable_count} selected test(s) were UNRUNNABLE; install the missing runtime and re-run /run-tests`
        : "the failing run recorded no unrunnable_count; re-run /run-tests";
      return classification;
    }
    verdict.code = EXIT.OK;
    verdict.reason = null;
    verdict.basis = agg.basis;
    const clean = disposition.sanitizeNote(note);
    // run_outcome "pass": a failing value would make write-code-resume reopen
    // write_code; the real nature of this completion lives in completion_basis.
    return classification.concat([
      annotation("run_outcome", "pass"),
      annotation("completion_basis", agg.basis),
    ].concat(clean === null ? [] : [annotation("baseline_note", clean)], [
      { kind: "step_status", step: "run_tests", status: "complete", provenance: "observed", origin: ORIGIN },
    ]));
  });
  return verdict;
}

function recordFromFile(sessionId, seq, file, base, note) {
  let entries;
  try {
    entries = parseClassification(fs.readFileSync(file, "utf8"));
  } catch (e) {
    return { code: EXIT.USAGE, reason: `cannot read classification: ${e.message}` };
  }
  try {
    return record(sessionId, seq, entries, base, note);
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
  hitCount,
};
