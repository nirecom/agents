"use strict";
// hooks/lib/null-freshness.js
// #2400 — the single null-freshness policy shared by the user_verification (TR5)
// sentinel gate and the pre-merge backstop: whether the last TR5 terminal run may
// certify a null freshness_key, why it may not, and the arm-set filter for null keys.

const { ARTIFACT_NAMES } = require("./diff-fingerprint");
const { NON_BLOCK_TERMINAL_VERDICTS } = require("./supervisor-state-schema");

const NULL_KIND = Object.freeze({
  NOT_NULL: "not-null",
  CODE_SIDE: "code-side",
  ARTIFACT_SIDE: "artifact-side",
  UNAVAILABLE: "unavailable",
});

const REFUSAL = Object.freeze({
  UNAVAILABLE: "freshness-unavailable",
  NOT_NULL: "not-null",
  NO_TR5_RUN: "no-tr5-run",
  VERDICT_NOT_ALLOWED: "verdict-not-allowed",
  LATER_BLOCK: "later-block",
  NO_ARTIFACT_BREAKDOWN: "no-artifact-breakdown",
  NO_TRIGGER_KEY: "no-trigger-key",
  INPUTS_MOVED: "inputs-moved",
});

const CODE_DIFF_COMPONENT = "code diff (input_version)";
const UNAVAILABLE_TEXT = "the freshness key could not be computed for this working tree (fail-closed).";
const KIND_LABEL = {
  [NULL_KIND.CODE_SIDE]: "code side uncomputable: input_version is null",
  [NULL_KIND.ARTIFACT_SIDE]: "a plan artifact is missing",
};

function isNonEmptyString(v) {
  return typeof v === "string" && v.length > 0;
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function classifyNullFreshness(freshness) {
  if (!freshness || typeof freshness !== "object") return NULL_KIND.UNAVAILABLE;
  if (isNonEmptyString(freshness.freshness_key)) return NULL_KIND.NOT_NULL;
  if (!isPlainObject(freshness.artifact_keys)) return NULL_KIND.UNAVAILABLE;
  if (isNonEmptyString(freshness.input_version)) return NULL_KIND.ARTIFACT_SIDE;
  return NULL_KIND.CODE_SIDE;
}

function storedTriggerKey(tr5Run) {
  const keys = tr5Run && tr5Run.trigger_input_keys;
  if (!keys || typeof keys !== "object") return null;
  return typeof keys.TR5 === "string" ? keys.TR5 : null;
}

// No fallback to run.input_version: only the recorded TR5 trigger key counts (#2360).
function inputVersionMatches(tr5Run, currentInputVersion) {
  const stored = storedTriggerKey(tr5Run);
  return stored !== null && stored === currentInputVersion;
}

// Absence is compared as a value (null === null); a missing or malformed stored
// breakdown returns null so the caller fails closed.
function movedArtifacts(tr5Run, currentArtifactKeys) {
  const stored = tr5Run && tr5Run.artifact_keys;
  if (!isPlainObject(stored)) return null;
  const current = isPlainObject(currentArtifactKeys) ? currentArtifactKeys : {};
  const moved = [];
  for (const name of ARTIFACT_NAMES) {
    if (!Object.prototype.hasOwnProperty.call(stored, name)) return null;
    const s = stored[name];
    if (s !== null && !isNonEmptyString(s)) return null;
    const c = current[name] === undefined ? null : current[name];
    if (s !== c) moved.push(name);
  }
  return moved;
}

function evaluateNullFreshnessRecovery({ freshness, tr5Run, laterBlockExists } = {}) {
  const kind = classifyNullFreshness(freshness);
  const verdict = tr5Run ? tr5Run.verdict : null;
  const refuse = (refusal, moved) => ({ approve: false, kind, refusal, moved: moved || [], verdict });

  if (kind === NULL_KIND.UNAVAILABLE) return refuse(REFUSAL.UNAVAILABLE);
  if (kind === NULL_KIND.NOT_NULL) return refuse(REFUSAL.NOT_NULL);
  if (!tr5Run) return refuse(REFUSAL.NO_TR5_RUN);
  if (!NON_BLOCK_TERMINAL_VERDICTS.includes(tr5Run.verdict)) return refuse(REFUSAL.VERDICT_NOT_ALLOWED);
  if (laterBlockExists === true) return refuse(REFUSAL.LATER_BLOCK);

  const artifactsMoved = movedArtifacts(tr5Run, freshness.artifact_keys);
  if (artifactsMoved === null) return refuse(REFUSAL.NO_ARTIFACT_BREAKDOWN);

  const moved = [];
  if (kind === NULL_KIND.ARTIFACT_SIDE) {
    if (!isNonEmptyString(storedTriggerKey(tr5Run))) return refuse(REFUSAL.NO_TRIGGER_KEY);
    if (!inputVersionMatches(tr5Run, freshness.input_version)) moved.push(CODE_DIFF_COMPONENT);
  }
  moved.push(...artifactsMoved);
  if (moved.length > 0) return refuse(REFUSAL.INPUTS_MOVED, moved);

  return { approve: true, kind, refusal: null, moved: [], verdict };
}

function describeNullFreshnessRefusal(result) {
  const r = result || {};
  if (r.refusal === REFUSAL.UNAVAILABLE) return UNAVAILABLE_TEXT;
  const prefix = `the freshness key is null (${KIND_LABEL[r.kind] || r.kind})`;
  switch (r.refusal) {
    case REFUSAL.VERDICT_NOT_ALLOWED: {
      const verdict = isNonEmptyString(r.verdict) ? r.verdict : "none";
      const allowList = NON_BLOCK_TERMINAL_VERDICTS.join(", ");
      return `${prefix} and the last TR5 verdict (${verdict}) is not in the null-freshness allow-list (${allowList}) (fail-closed).`;
    }
    case REFUSAL.LATER_BLOCK:
      return `${prefix} and a later audit BLOCK verdict (post-TR5) is unresolved.`;
    case REFUSAL.NO_ARTIFACT_BREAKDOWN:
      return `${prefix} and the TR5 run recorded no per-artifact hashes to compare (fail-closed).`;
    case REFUSAL.NO_TRIGGER_KEY:
      return `${prefix} and the TR5 run recorded no trigger key to compare the code diff against (fail-closed).`;
    case REFUSAL.INPUTS_MOVED:
      return `${prefix} and inputs moved since the TR5 verdict — changed: ${(r.moved || []).join(", ")}.`;
    default:
      return `${prefix} and the null-freshness recovery was refused (${r.refusal}) (fail-closed).`;
  }
}

// recurrence-patterns keys on freshness_key, so with a null key it can never
// settle; arming it would re-arm forever (#2360).
function filterNullKeySubChecks(ids, freshness) {
  if (freshness && freshness.freshness_key == null) {
    return ids.filter((id) => id !== "recurrence-patterns");
  }
  return ids;
}

module.exports = {
  NULL_KIND,
  REFUSAL,
  classifyNullFreshness,
  inputVersionMatches,
  movedArtifacts,
  evaluateNullFreshnessRecovery,
  describeNullFreshnessRefusal,
  filterNullKeySubChecks,
};
