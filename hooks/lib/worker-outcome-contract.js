"use strict";
// hooks/lib/worker-outcome-contract.js
// The shape of one dispatch outcome record and the names of the control files
// that belong to it (#2544). The dispatcher writes it and the run_tests hook reads
// it, so both sides take the vocabulary from here. A dispatch is identified by its
// payload stem plus the payload's sha256; file names carry the stem only.
// Standard library only: the dispatcher loads this before any worker runs.
const crypto = require("crypto");

const SCHEMA_VERSION = 1;
const OUTCOME_STATUSES = Object.freeze(["pass", "fail", "timeout", "runner-error"]);
const RUN_CONTRACT_KEYS = Object.freeze(["pass", "fail", "skip", "executed"]);
// Equals the YAML renderer's summary cap, so the record re-renders without truncation.
const MAX_OUTCOME_SUMMARY = 296;

const WORKER_NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const SHA256_RE = /^[0-9a-f]{64}$/;

const outcomeFileName = (stem) => `${stem}.outcome.json`;
const ingestedMarkerName = (stem) => `${stem}.ingested`;

function payloadDigest(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isNonEmptyString = (v) => typeof v === "string" && v.length > 0;
const isStringList = (v) => Array.isArray(v) && v.every((x) => typeof x === "string");
const isCount = (v) => Number.isInteger(v) && v >= 0;
const orNull = (v) => (v === undefined ? null : v);

function stemBelongsTo(stem, worker) {
  const base = `worker-${worker}`;
  if (stem === base) return true;
  return stem.startsWith(`${base}-`) && /^[0-9]+$/.test(stem.slice(base.length + 1));
}

function copyRunContract(value) {
  if (!isPlainObject(value)) return orNull(value);
  const out = {};
  for (const key of RUN_CONTRACT_KEYS) out[key] = value[key];
  return out;
}

function copyWorkerResult(value) {
  if (!isPlainObject(value)) return orNull(value);
  return {
    run_contract: copyRunContract(value.run_contract),
    failing_tests: Array.isArray(value.failing_tests) ? value.failing_tests.slice() : orNull(value.failing_tests),
    log_tail: Array.isArray(value.log_tail) ? value.log_tail.slice() : orNull(value.log_tail),
    summary: orNull(value.summary),
  };
}

// Shapes the record and fixes its key order. It does not judge the values:
// validateOutcome is the only judge, for the writer and the reader alike.
function buildOutcome(fields) {
  const f = isPlainObject(fields) ? fields : {};
  return {
    schema_version: f.schema_version === undefined ? SCHEMA_VERSION : f.schema_version,
    worker: orNull(f.worker),
    stem: orNull(f.stem),
    session_id: orNull(f.session_id),
    payload_sha256: orNull(f.payload_sha256),
    cwd: orNull(f.cwd),
    status: orNull(f.status),
    exit_code: orNull(f.exit_code),
    duration_ms: orNull(f.duration_ms),
    worker_result: copyWorkerResult(f.worker_result),
  };
}

function runContractProblem(value) {
  if (value === null || value === undefined) return null;
  if (!isPlainObject(value)) return "worker_result.run_contract must be an object or null";
  for (const key of RUN_CONTRACT_KEYS) {
    if (!isCount(value[key])) return `worker_result.run_contract.${key} must be a non-negative integer`;
  }
  return null;
}

function workerResultProblem(value) {
  if (!isPlainObject(value)) return "worker_result must be an object";
  if (!isStringList(value.failing_tests)) return "worker_result.failing_tests must be a list of strings";
  if (!isStringList(value.log_tail)) return "worker_result.log_tail must be a list of strings";
  if (typeof value.summary !== "string") return "worker_result.summary must be a string";
  if (value.summary.length > MAX_OUTCOME_SUMMARY) {
    return `worker_result.summary must be at most ${MAX_OUTCOME_SUMMARY} characters`;
  }
  return runContractProblem(value.run_contract);
}

function outcomeProblem(o) {
  if (!isPlainObject(o)) return "outcome must be an object";
  if (o.schema_version !== SCHEMA_VERSION) return `schema_version must be ${SCHEMA_VERSION}`;
  if (typeof o.worker !== "string" || !WORKER_NAME_RE.test(o.worker)) return "worker must be a worker name";
  if (typeof o.stem !== "string") return "stem must be a string";
  if (!stemBelongsTo(o.stem, o.worker)) return "stem must be worker-<worker> or worker-<worker>-<sequence>";
  if (!isNonEmptyString(o.session_id)) return "session_id must be a non-empty string";
  if (typeof o.payload_sha256 !== "string" || !SHA256_RE.test(o.payload_sha256)) {
    return "payload_sha256 must be 64 lowercase hex characters";
  }
  // Empty when the payload carried no string cwd: the record still names the dispatch.
  if (typeof o.cwd !== "string") return "cwd must be a string";
  if (!OUTCOME_STATUSES.includes(o.status)) return `status must be one of ${OUTCOME_STATUSES.join(", ")}`;
  if (!Number.isInteger(o.exit_code)) return "exit_code must be an integer";
  if (typeof o.duration_ms !== "number" || !Number.isFinite(o.duration_ms) || o.duration_ms < 0) {
    return "duration_ms must be a non-negative number";
  }
  return workerResultProblem(o.worker_result);
}

function validateOutcome(obj) {
  try {
    const reason = outcomeProblem(obj);
    if (reason !== null) return { ok: false, reason };
    return { ok: true, outcome: buildOutcome(obj) };
  } catch (e) {
    return { ok: false, reason: `outcome could not be read: ${e && e.message ? e.message : "unknown error"}` };
  }
}

module.exports = {
  SCHEMA_VERSION,
  OUTCOME_STATUSES,
  MAX_OUTCOME_SUMMARY,
  outcomeFileName,
  ingestedMarkerName,
  payloadDigest,
  buildOutcome,
  validateOutcome,
};
