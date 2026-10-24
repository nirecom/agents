"use strict";
// hooks/lib/null-freshness/acceptance.js
// #2597 / #2536 — the reviewed verdict acceptance (audit.block_overrides) both TR5 gates honour,
// and the shape checks every state-derived value passes before it is interpolated into a
// deny reason the main conversation reads.

const { ARTIFACT_NAMES } = require("../diff-fingerprint");
const { RUN_ID_RE } = require("../audit-ledger");
const { AUDIT_VERDICT_VALUES, UNSETTLED_AUDIT_PHASES } = require("../supervisor-state-schema");

// Verdicts a user may accept after review; CONTINUE needs no acceptance.
const ACCEPTABLE_VERDICTS = Object.freeze(["WARN", "BLOCK"]);
const MIN_REASON_LEN = 20;
const SENTINEL_NAME = "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED";

function isNonEmptyString(v) {
  return typeof v === "string" && v.length > 0;
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function safeRunId(v) {
  return typeof v === "string" && RUN_ID_RE.test(v) ? v : "<invalid-run-id>";
}

function safeVerdict(v) {
  return typeof v === "string" && AUDIT_VERDICT_VALUES.includes(v) ? v : "<invalid-verdict>";
}

function safePhase(v) {
  return typeof v === "string" && UNSETTLED_AUDIT_PHASES.includes(v) ? v : "<invalid-phase>";
}

function storedTriggerKey(tr5Run) {
  const keys = tr5Run && tr5Run.trigger_input_keys;
  if (!keys || typeof keys !== "object") return null;
  return typeof keys.TR5 === "string" ? keys.TR5 : null;
}

// "" and non-strings collapse to null so a run recorded with an empty key compares as null.
function keyOrNull(v) {
  return isNonEmptyString(v) ? v : null;
}

// A record written before #2597 carries no verdict: it was a BLOCK override (the recorder
// refused anything else), so it maps to BLOCK and stays valid only on the non-null path.
function normalizeAcceptance(rec) {
  if (!isPlainObject(rec)) return null;
  if (typeof rec.run_id !== "string" || !RUN_ID_RE.test(rec.run_id)) return null;
  const legacy = rec.verdict === undefined || rec.verdict === null;
  if (!legacy && !ACCEPTABLE_VERDICTS.includes(rec.verdict)) return null;
  return {
    run_id: rec.run_id,
    verdict: legacy ? "BLOCK" : rec.verdict,
    legacy,
    freshness_key: keyOrNull(rec.freshness_key),
    artifact_keys: !legacy && isPlainObject(rec.artifact_keys) ? rec.artifact_keys : null,
    trigger_key: !legacy && typeof rec.trigger_key === "string" ? rec.trigger_key : null,
  };
}

// The null-key path has no freshness_key to pin, so the acceptance must pin the run's whole
// snapshot: freshness_key, every artifact hash and the TR5 trigger key.
function acceptanceMatchesRun(acc, tr5Run) {
  if (!acc || acc.legacy || !tr5Run) return false;
  if (acc.freshness_key !== keyOrNull(tr5Run.freshness_key)) return false;
  const mine = acc.artifact_keys;
  const theirs = tr5Run.artifact_keys;
  if (!isPlainObject(mine) || !isPlainObject(theirs)) return false;
  for (const name of ARTIFACT_NAMES) {
    if (!Object.prototype.hasOwnProperty.call(mine, name)) return false;
    if (!Object.prototype.hasOwnProperty.call(theirs, name)) return false;
    if (mine[name] !== theirs[name]) return false;
  }
  return acc.trigger_key === storedTriggerKey(tr5Run);
}

// The newest record for this ledger run (always tr5Run.id, never a run_id field) and verdict.
function findAcceptance(overrides, tr5Run) {
  if (!tr5Run || !isNonEmptyString(tr5Run.id) || !Array.isArray(overrides)) return null;
  for (let i = overrides.length - 1; i >= 0; i--) {
    const acc = normalizeAcceptance(overrides[i]);
    if (acc && acc.run_id === tr5Run.id && acc.verdict === tr5Run.verdict) return acc;
  }
  return null;
}

// Non-null path: the freshness_key pin alone proves nothing moved since the acceptance.
function acceptanceReleasesNonNull({ tr5Run, overrides, currentFk } = {}) {
  if (!isNonEmptyString(currentFk)) return false;
  const acc = findAcceptance(overrides, tr5Run);
  return Boolean(acc) && acc.freshness_key === currentFk;
}

function describeAcceptanceCommand(runId) {
  return "If the user has reviewed the findings and accepts this verdict, record the acceptance " +
    `from the main conversation: echo "<<${SENTINEL_NAME}: ${safeRunId(runId)} <reason>>>" ` +
    `(the user's approval dialog appears; <reason> is at least ${MIN_REASON_LEN} characters).`;
}

module.exports = {
  ACCEPTABLE_VERDICTS,
  MIN_REASON_LEN,
  SENTINEL_NAME,
  isNonEmptyString,
  isPlainObject,
  safeRunId,
  safeVerdict,
  safePhase,
  storedTriggerKey,
  normalizeAcceptance,
  acceptanceMatchesRun,
  findAcceptance,
  acceptanceReleasesNonNull,
  describeAcceptanceCommand,
};
