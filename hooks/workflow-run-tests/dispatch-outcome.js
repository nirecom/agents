"use strict";
// hooks/workflow-run-tests/dispatch-outcome.js — the file route of run_tests (#2544).
// The dispatcher leaves <stem>.outcome.json in the session control dir; any later
// Bash call ingests it, whatever its command. readTrustedOutcome is the one
// implementation of the trust conditions, shared with show-dispatch-outcome.js.
// Trust model: docs/architecture/claude-code/settings/hooks.md.

const fs = require("fs");
const path = require("path");
const { readState } = require("../workflow-state");
const { getSessionControlDir, assertRealControlDir } = require("../workflow-state/state-io/control-dir");
const { latestDispatch } = require("../workflow-state/dispatch-settlement");
const {
  outcomeFileName,
  ingestedMarkerName,
  payloadDigest,
  validateOutcome,
} = require("../lib/worker-outcome-contract");
const { normalizeCwd } = require("../lib/path-normalize");
const { workerVerdictVetoes } = require("./outcome");
const { validateFailingNames } = require("./failing-list");
const { recordRun, recordUnsettled } = require("./record-run");

const WORKER = "test-runner";

const refuse = (reason) => ({ outcome: null, outcomeSha: null, payloadSha: null, reason });

// Bytes of a regular file in the control dir; a symlink or anything else is refused.
function readRegular(dir, name) {
  const p = path.join(dir, name);
  let st;
  try {
    st = fs.lstatSync(p);
  } catch (e) {
    if (e && e.code === "ENOENT") return { missing: true };
    throw e;
  }
  if (!st.isFile()) return { irregular: true };
  return { bytes: fs.readFileSync(p) };
}

function parseJson(bytes) {
  try {
    return { value: JSON.parse(bytes.toString("utf8")) };
  } catch (_) {
    return null;
  }
}

// -> { outcome, outcomeSha, payloadSha, reason }; outcome is null unless every
// trust condition holds. Read-only.
function readTrustedOutcome({ sessionId, stem } = {}) {
  const dir = getSessionControlDir(sessionId);
  if (!assertRealControlDir(dir)) return refuse("absent");
  const file = readRegular(dir, outcomeFileName(stem));
  if (file.missing) return refuse("absent");
  if (file.irregular) return refuse("not-regular");
  const parsed = parseJson(file.bytes);
  if (parsed === null) return refuse("not-json");
  const v = validateOutcome(parsed.value);
  if (!v.ok) return refuse("invalid-shape");
  const o = v.outcome;
  if (o.worker !== WORKER) return refuse("worker-mismatch");
  if (o.stem !== stem) return refuse("stem-mismatch");
  if (o.session_id !== sessionId) return refuse("session-mismatch");
  const payload = readRegular(dir, `${stem}.json`);
  if (payload.missing || payload.irregular) return refuse("payload-missing");
  const payloadSha = payloadDigest(payload.bytes);
  if (payloadSha !== o.payload_sha256) return refuse("payload-digest-mismatch");
  const body = parseJson(payload.bytes);
  const p = body !== null && body.value !== null && typeof body.value === "object" ? body.value : {};
  if (o.cwd !== (typeof p.cwd === "string" ? p.cwd : "")) return refuse("cwd-mismatch");
  if (p.session_id !== undefined && p.session_id !== sessionId) return refuse("payload-session-mismatch");
  if (!fs.existsSync(path.join(dir, `${stem}.dispatched`))) return refuse("not-dispatched");
  return { outcome: o, outcomeSha: payloadDigest(file.bytes), payloadSha, reason: null };
}

// The list only when every name also exists under the run's cwd; else null whole.
function trustedFailingList(outcome, contract) {
  if (contract === null || contract.fail === 0) return null;
  const names = validateFailingNames(outcome.worker_result.failing_tests, outcome.cwd, contract);
  if (names === null) return null;
  const root = normalizeCwd(outcome.cwd) || outcome.cwd;
  return names.every((rel) => fs.existsSync(path.join(root, rel))) ? names : null;
}

function buildIngest(stem, trusted) {
  const o = trusted.outcome;
  const contract = o.worker_result.run_contract;
  return {
    stem,
    outcome: o,
    outcomeSha: trusted.outcomeSha,
    payloadSha: trusted.payloadSha,
    outcomeInput: {
      emitter: "worker-dispatch",
      ambiguous: false,
      attributed: true,
      vetoed: workerVerdictVetoes(o.status, o.exit_code),
      contract,
      workerStatus: o.status,
    },
    failingTests: trustedFailingList(o, contract),
  };
}

const controlFileExists = (sessionId, name) => {
  const dir = getSessionControlDir(sessionId);
  return assertRealControlDir(dir) && fs.existsSync(path.join(dir, name));
};

// -> { latestStem, ingest, unsettled, reason }. Only the latest dispatch counts.
function settleDispatchOutcome(sessionId) {
  const latest = latestDispatch({ sessionId, worker: WORKER });
  if (latest === null) return { latestStem: null, ingest: null, unsettled: false };
  const stem = latest.stem;
  if (controlFileExists(sessionId, ingestedMarkerName(stem))) {
    return { latestStem: stem, ingest: null, unsettled: false };
  }
  const trusted = readTrustedOutcome({ sessionId, stem });
  if (trusted.outcome === null) return { latestStem: stem, ingest: null, unsettled: true, reason: trusted.reason };
  return { latestStem: stem, ingest: buildIngest(stem, trusted), unsettled: false };
}

function markIngested(sessionId, stem) {
  const dir = getSessionControlDir(sessionId);
  if (!assertRealControlDir(dir)) return false;
  try {
    fs.writeFileSync(path.join(dir, ingestedMarkerName(stem)), `${new Date().toISOString()}\n`, { flag: "wx" });
  } catch (e) {
    if (!e || e.code !== "EEXIST") throw e;
  }
  return true;
}

function runTestsEntry(sessionId) {
  const state = readState(sessionId);
  return state && state.steps && state.steps.run_tests ? state.steps.run_tests : null;
}

// State already names these exact outcome bytes: a lost marker is rebuilt, nothing re-recorded.
function alreadyRecorded(entry, ingest) {
  const src = entry ? entry.outcome_source : null;
  return src !== null && typeof src === "object" && src.stem === ingest.stem && src.outcome_sha256 === ingest.outcomeSha;
}

const present = (v) => v !== null && v !== undefined;

// complete, or pending with a stale observation; skipped is never touched.
function holdsStaleResult(entry) {
  if (!entry) return false;
  if (entry.status === "complete") return true;
  return entry.status === "pending" && (present(entry.run_outcome) || present(entry.failing_tests));
}

function recordIngest(sessionId, ingest) {
  const entry = runTestsEntry(sessionId);
  let message = null;
  if (!alreadyRecorded(entry, ingest)) {
    message = recordRun({
      sessionId,
      exitCode: ingest.outcome.exit_code,
      triggerCommand: `worker-dispatch outcome ${ingest.stem}`,
      outcomeInput: ingest.outcomeInput,
      failingTests: ingest.failingTests,
      source: { stem: ingest.stem, payload_sha256: ingest.payloadSha, outcome_sha256: ingest.outcomeSha },
    });
  }
  // State first, marker second: a stop in between replays as a no-op.
  markIngested(sessionId, ingest.stem);
  return message;
}

// -> { ingested, unsettledStem, message }. A non-test call demotes a stale result
// of an unsettled dispatch here; a test call leaves that to recordRun.
function applyDispatchOutcome({ sessionId, triggerCommand, isTest }) {
  const s = settleDispatchOutcome(sessionId);
  if (s.ingest !== null) {
    return { ingested: true, unsettledStem: null, message: recordIngest(sessionId, s.ingest) };
  }
  if (!s.unsettled) return { ingested: false, unsettledStem: null, message: null };
  let message = null;
  if (!isTest && holdsStaleResult(runTestsEntry(sessionId))) {
    message = recordUnsettled({ sessionId, stem: s.latestStem, triggerCommand });
  }
  return { ingested: false, unsettledStem: s.latestStem, message };
}

module.exports = {
  readTrustedOutcome,
  settleDispatchOutcome,
  markIngested,
  applyDispatchOutcome,
};
