"use strict";
// bin/workflow/lib/session-facts/collect.js
// Composition only: three independent read-only lookups, one fixed record.

// Failure contract, per family (CPR-SC):
//   exit 0 — every key carries a value; gate and complexity failures degrade to
//            ERROR / NONE, never to an exit code.
//   exit 3 — PLANS_DIR is unresolvable. Every key is STILL printed, with
//            PLANS_DIR=NONE, and the reason goes to stderr. Fail-closed, because
//            a caller that builds `NONE/<sid>-...` writes to the wrong place.
// Usage errors belong to the CLI, which prints nothing at all.

const path = require("path");
const { FACTS_VERSION, FACTS_KEYS } = require("./keys");
const { modelForLevel } = require("../../../../hooks/lib/role-model");
const { readGateFacts } = require("./gate-facts");
const { resolveConfigDir } = require("../../../../hooks/lib/confirm-gate/probe");
const { getWorkflowPlansDir } = require("../../../../hooks/lib/workflow-plans-dir");
const { readComplexityEvaluation } = require("../../../../hooks/workflow-state");
const { normalizeCwd } = require("../../../../hooks/lib/path-normalize");
const { SIGNAL_IDS } = require("../../../../hooks/workflow-state/complexity-routing");
const { getSessionControlDir } = require("../../../../hooks/workflow-state/state-io/control-dir");

const NONE = "NONE";
const LEVELS = ["high", "low"];

function resolvePlansDir() {
  let raw;
  try {
    raw = getWorkflowPlansDir();
  } catch (e) {
    return { value: NONE, error: e && e.message ? e.message : String(e) };
  }
  if (typeof raw !== "string" || raw === "" || /[\r\n]/.test(raw)) {
    return {
      value: NONE,
      error: "WORKFLOW_PLANS_DIR must be an absolute path on a single line",
    };
  }
  const normalized = normalizeCwd(raw) || raw;
  if (!path.isAbsolute(normalized)) {
    return {
      value: NONE,
      error: "WORKFLOW_PLANS_DIR must be an absolute path. Got: " + normalized,
    };
  }
  return { value: normalized, error: null };
}

// Path only: reading the facts never creates <sid>.control (writers go through controlPath).
function resolveControlDir(sessionId) {
  try {
    const dir = getSessionControlDir(sessionId);
    return /[\r\n]/.test(dir) ? NONE : dir;
  } catch (_) {
    return NONE;
  }
}

function levelOf(levels, stage) {
  if (!levels || typeof levels !== "object") return NONE;
  const v = levels[stage];
  return LEVELS.indexOf(v) !== -1 ? v : NONE;
}

function modelOf(level) {
  return level === NONE ? NONE : modelForLevel(level);
}

function readComplexityFacts(sessionId) {
  let ce = null;
  try {
    ce = readComplexityEvaluation(sessionId);
  } catch (e) {
    ce = null;
  }
  if (!ce) {
    return {
      COMPLEXITY_LEVEL_write_tests: NONE,
      COMPLEXITY_LEVEL_write_code: NONE,
      COMPLEXITY_MODEL_write_tests: NONE,
      COMPLEXITY_MODEL_write_code: NONE,
      COMPLEXITY_SIGNALS: NONE,
    };
  }
  const signals = Array.isArray(ce.signals)
    ? ce.signals.filter((s) => typeof s === "string" && SIGNAL_IDS.includes(s))
    : [];
  const testsLevel = levelOf(ce.levels, "write_tests");
  const codeLevel = levelOf(ce.levels, "write_code");
  return {
    COMPLEXITY_LEVEL_write_tests: testsLevel,
    COMPLEXITY_LEVEL_write_code: codeLevel,
    COMPLEXITY_MODEL_write_tests: modelOf(testsLevel),
    COMPLEXITY_MODEL_write_code: modelOf(codeLevel),
    COMPLEXITY_SIGNALS: signals.length ? signals.join(",") : "none",
  };
}

async function collectSessionFacts(sessionId) {
  const plans = resolvePlansDir();
  const gates = await readGateFacts(resolveConfigDir());
  const values = Object.assign(
    {
      FACTS_VERSION: String(FACTS_VERSION),
      SESSION_ID: sessionId,
      PLANS_DIR: plans.value,
      CONTROL_DIR: resolveControlDir(sessionId),
    },
    gates,
    readComplexityFacts(sessionId)
  );
  return {
    lines: FACTS_KEYS.map((k) => k + "=" + values[k]),
    errors: plans.error ? [plans.error] : [],
    exitCode: plans.error ? 3 : 0,
  };
}

module.exports = { collectSessionFacts };
