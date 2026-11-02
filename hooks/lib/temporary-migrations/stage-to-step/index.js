"use strict";
// --- BEGIN temporary: workflow stage -> workflow step migration added 2026-11-02 ---
// deletion-condition: remove once 30 days (the control dir lifetime) have passed since merge and no --stage caller remains in this repo or the global instructions
// #2820: the one place that reads the legacy stage vocabulary. Callers keep a single line inside
// their own block that calls into here, so deleting this folder plus those blocks retires it.
const path = require("path");

const hasOwn = (obj, k) => typeof k === "string" && Object.prototype.hasOwnProperty.call(obj, k);

// The glossary check's legacy stage values (record field, sentinel discriminator, CLI value).
const LEGACY_GLOSSARY_STAGE_TO_STEP = Object.freeze({
  intent: "clarify_intent",
  outline: "outline",
  detail: "detail",
  tests: "review_tests",
  code: "review_security",
  docs: "review_docs",
});

// The plan CLIs' legacy values were the plan artifact names.
const LEGACY_PLAN_ARTIFACT_TO_STEP = Object.freeze({
  intent: "clarify_intent",
  outline: "outline",
  detail: "detail",
});

const LEGACY_STAGE_ARG_OF_CLI = Object.freeze({
  "check-glossary-drift": LEGACY_GLOSSARY_STAGE_TO_STEP,
  "plan-artifact-path": LEGACY_PLAN_ARTIFACT_TO_STEP,
  "plan-link": LEGACY_PLAN_ARTIFACT_TO_STEP,
});

function stepOfLegacyGlossaryStage(v) {
  return hasOwn(LEGACY_GLOSSARY_STAGE_TO_STEP, v) ? LEGACY_GLOSSARY_STAGE_TO_STEP[v] : null;
}

// A legacy glossary_check record ({stage}) becomes {step}; the input is not mutated.
function normalizeGlossaryRecord(rec) {
  if (!rec || typeof rec !== "object" || !("stage" in rec) || "step" in rec) return rec;
  const out = {};
  for (const [k, v] of Object.entries(rec)) {
    if (k === "stage") out.step = stepOfLegacyGlossaryStage(v) || v;
    else out[k] = v;
  }
  return out;
}

// The receipt file name before #2820 was keyed by the plan artifact name.
function legacyReceiptPath(sid, step) {
  const { rowFor } = require("../../../workflow-state/plan-step-table");
  const row = rowFor(step);
  if (!row) return null;
  const { getSessionStateDir } = require("../../../workflow-state");
  return path.join(getSessionStateDir(sid), `${sid}.confirm-plan-receipt-${row.suffix}.json`);
}

// A receipt log line written before #2820 ({event, stage, path, at}) becomes {event, step, path, at}.
function normalizeReceiptLogLine(l) {
  if (!l || typeof l !== "object" || !("stage" in l) || "step" in l) return l;
  const out = {};
  for (const [k, v] of Object.entries(l)) {
    if (k === "stage") out.step = hasOwn(LEGACY_PLAN_ARTIFACT_TO_STEP, v) ? LEGACY_PLAN_ARTIFACT_TO_STEP[v] : v;
    else out[k] = v;
  }
  return out;
}

// stepOfLegacyStageArg(cli, v) -> the step a CLI's deprecated --stage value names, or null.
function stepOfLegacyStageArg(cli, v) {
  if (!hasOwn(LEGACY_STAGE_ARG_OF_CLI, cli)) return null;
  const map = LEGACY_STAGE_ARG_OF_CLI[cli];
  if (!hasOwn(map, v)) return null;
  const step = map[v];
  process.stderr.write(`${cli}: --stage is deprecated; use --step ${step}\n`);
  return step;
}

module.exports = {
  LEGACY_GLOSSARY_STAGE_TO_STEP,
  stepOfLegacyGlossaryStage,
  normalizeGlossaryRecord,
  legacyReceiptPath,
  normalizeReceiptLogLine,
  stepOfLegacyStageArg,
};
// --- END temporary: workflow stage -> workflow step migration ---
