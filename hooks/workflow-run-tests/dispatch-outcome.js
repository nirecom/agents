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
const { listUnconsumed } = require("../workflow-state/dispatch-settlement");
const {
  outcomeFileName,
  ingestedMarkerName,
  payloadDigest,
  validateOutcome,
} = require("../lib/worker-outcome-contract");
const { normalizeCwd } = require("../lib/path-normalize");
const { parseContractLine, formatContract, runtimeLabels } = require("../lib/run-contract");
const { SUMMARY_MISSING_RE, readSummaryToken } = require("../lib/missing-test-files");
const { workerVerdictVetoes } = require("./outcome");
const { validateFailingNames, filterFailingExits } = require("./failing-list");
const { recordRun, recordUnsettled } = require("./record-run");
const { boundHits } = require("./hit-summary");
const { withStateLock } = require("../workflow-state/state-io/state-lock");

const WORKER = "test-runner";
// Stands for "the control dir could not be scanned"; parseStem never takes it for a real stem.
const SCAN_FAILED_STEM = "control-dir-scan-failed";

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
  return { outcome: o, outcomeSha: payloadDigest(file.bytes), payloadSha, payload: p, reason: null };
}

// The list only when every name also exists under the run's cwd; else null whole.
function trustedFailingList(outcome, contract) {
  if (contract === null || contract.fail === 0) return null;
  const names = validateFailingNames(outcome.worker_result.failing_tests, outcome.cwd, contract);
  if (names === null) return null;
  const root = normalizeCwd(outcome.cwd) || outcome.cwd;
  return names.every((rel) => fs.existsSync(path.join(root, rel))) ? names : null;
}

// The record's contract re-parsed by the one strict parser, so it carries its shape and a
// self-inconsistent count is no contract — exactly as the same line on stdout would be.
function parsedContract(value) {
  if (value === null || value === undefined) return null;
  const shape = value.unrunnable !== undefined ? "current" : "legacy";
  return parseContractLine(formatContract(Object.assign({}, value, { shape })));
}

// The worker leads its summary with the suite's `Missing runtimes:` text (D5-7), after the
// optional `Missing test files: N; ` token (#2646).
function summaryRuntimes(summary) {
  const m = SUMMARY_MISSING_RE.exec(typeof summary === "string" ? summary : "");
  return m === null ? null : runtimeLabels(m[1]);
}

function buildIngest(stem, trusted, late) {
  const o = trusted.outcome;
  const contract = parsedContract(o.worker_result.run_contract);
  const failingTests = trustedFailingList(o, contract);
  const args = trusted.payload ? trusted.payload.test_args : undefined;
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
    failingTests,
    failingExits: filterFailingExits(o.worker_result.failing_exits, failingTests, o.cwd),
    // The selection comes from the payload the dispatcher ran, never from the outcome's words.
    part: { args: args === undefined ? [] : args, root: o.cwd, cwd: o.cwd, results: null, late: late === true },
    hitSummary: boundHits(o.worker_result.hits || []),
    unrunnableRuntimes: summaryRuntimes(o.worker_result.summary),
    unrunnableMissingFiles: readSummaryToken(o.worker_result.summary),
  };
}

// -> { ingests, unsettled, unsettledStem, reason }, every unconsumed dispatch in dispatch order (#3063).
// ingests: the trusted outcomes, each with the unusable stems older than it (olderUnsettled);
// unsettled: the stems whose outcome is absent or untrusted, unsettledStem the oldest of them.
// A scan failure is never "no dispatch": unsettledStem is SCAN_FAILED_STEM and reason says why.
function settleDispatchOutcome(sessionId) {
  const u = listUnconsumed({ sessionId, worker: WORKER });
  if (u.reason) return { ingests: [], unsettled: [], unsettledStem: SCAN_FAILED_STEM, reason: u.reason };
  const ingests = [];
  const unsettled = [];
  for (const d of u.stems) {
    const trusted = readTrustedOutcome({ sessionId, stem: d.stem });
    if (trusted.outcome === null) {
      unsettled.push(d.stem);
      continue;
    }
    ingests.push(Object.assign(buildIngest(d.stem, trusted, d.late), { olderUnsettled: unsettled.slice() }));
  }
  return { ingests, unsettled, unsettledStem: unsettled.length > 0 ? unsettled[0] : null, reason: null };
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
      failingExits: ingest.failingExits,
      part: ingest.part,
      hitSummary: ingest.hitSummary,
      unrunnableRuntimes: ingest.unrunnableRuntimes,
      unrunnableMissingFiles: ingest.unrunnableMissingFiles,
      source: { stem: ingest.stem, payload_sha256: ingest.payloadSha, outcome_sha256: ingest.outcomeSha },
    });
  }
  // State first, marker second: a stop in between replays as a no-op.
  markIngested(sessionId, ingest.stem);
  return message;
}

// A full green-or-red run recorded from this ingest settles every older unusable dispatch:
// the only exit for a dispatch killed before it left an outcome (ARP-EXBG).
function supersedeOlder(sessionId, ingest, superseded) {
  if (ingest.part.late || ingest.part.provenSelection !== "full") return;
  for (const stem of ingest.olderUnsettled) {
    if (markIngested(sessionId, stem)) superseded.add(stem);
  }
}

function withScanReason(message, reason) {
  return message === null ? null : Object.assign({}, message, { detail: `${message.detail}\n${reason}` });
}

// -> { ingested, unsettledStem, message }. Every trusted outcome is recorded in dispatch order;
// a stale result of a still-unsettled dispatch is then demoted here — by a test call too once
// this call ingested something, since the stdout route stops there. Otherwise a test call leaves
// it to recordRun.
// One state lock spans scan -> record -> mark (#3063): a concurrent hook waits, then re-scans and
// sees the .ingested markers. A lock timeout throws before the scan, so nothing is consumed.
function applyDispatchOutcome(args) {
  return withStateLock(args.sessionId, () => applyLocked(args));
}

function applyLocked({ sessionId, triggerCommand, isTest }) {
  const s = settleDispatchOutcome(sessionId);
  let message = null;
  const superseded = new Set();
  for (const ingest of s.ingests) {
    message = recordIngest(sessionId, ingest) || message;
    supersedeOlder(sessionId, ingest, superseded);
  }
  const rest = s.unsettled.filter((stem) => !superseded.has(stem));
  const unsettledStem = superseded.size > 0 ? (rest.length > 0 ? rest[0] : null) : s.unsettledStem;
  const ingested = s.ingests.length > 0;
  if (unsettledStem !== null && (!isTest || ingested) && holdsStaleResult(runTestsEntry(sessionId))) {
    const m = recordUnsettled({ sessionId, stem: unsettledStem, triggerCommand });
    message = (s.reason ? withScanReason(m, s.reason) : m) || message;
  }
  return { ingested, unsettledStem, message };
}

module.exports = {
  SCAN_FAILED_STEM,
  readTrustedOutcome,
  settleDispatchOutcome,
  markIngested,
  applyDispatchOutcome,
};
