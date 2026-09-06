"use strict";
// bin/workflow/lib/session-facts/collect.js
// Composition only: three independent read-only lookups, one fixed record.

// Failure contract, per family (CPR-SC):
//   exit 0 — every key carries a value; gate and complexity failures degrade to
//            ERROR / NONE, never to an exit code.
//   exit 3 — PLANS_DIR is unresolvable. All eight keys are STILL printed, with
//            PLANS_DIR=NONE, and the reason goes to stderr. Fail-closed, because
//            a caller that builds `NONE/<sid>-...` writes to the wrong place.
// Usage errors belong to the CLI, which prints nothing at all.

const path = require("path");
const { FACTS_VERSION, FACTS_V1_KEYS } = require("./keys");
const { readGateFacts } = require("./gate-facts");
const { getWorkflowPlansDir } = require("../../../../hooks/lib/workflow-plans-dir");
const { readComplexityEvaluation } = require("../../../../hooks/workflow-state");
const { normalizeCwd } = require("../../../../hooks/lib/path-normalize");

const NONE = "NONE";
const LEVELS = ["high", "low"];
// State values are written by other tools and printed into a transcript the model
// parses as facts, so anything that could break the KEY=VALUE line structure or
// read as prose is dropped rather than escaped.
const SIGNAL_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

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

function levelOf(levels, stage) {
  if (!levels || typeof levels !== "object") return NONE;
  const v = levels[stage];
  return LEVELS.indexOf(v) !== -1 ? v : NONE;
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
      COMPLEXITY_SIGNALS: NONE,
    };
  }
  const signals = Array.isArray(ce.signals)
    ? ce.signals.filter((s) => typeof s === "string" && SIGNAL_ID_RE.test(s))
    : [];
  return {
    COMPLEXITY_LEVEL_write_tests: levelOf(ce.levels, "write_tests"),
    COMPLEXITY_LEVEL_write_code: levelOf(ce.levels, "write_code"),
    COMPLEXITY_SIGNALS: signals.length ? signals.join(",") : "none",
  };
}

function resolveConfigDir() {
  const fromEnv = normalizeCwd(process.env.AGENTS_CONFIG_DIR);
  if (fromEnv) return fromEnv;
  return path.resolve(__dirname, "..", "..", "..", "..");
}

async function collectSessionFacts(sessionId) {
  const plans = resolvePlansDir();
  const gates = await readGateFacts(resolveConfigDir());
  const values = Object.assign(
    {
      FACTS_VERSION: String(FACTS_VERSION),
      SESSION_ID: sessionId,
      PLANS_DIR: plans.value,
    },
    gates,
    readComplexityFacts(sessionId)
  );
  return {
    lines: FACTS_V1_KEYS.map((k) => k + "=" + values[k]),
    errors: plans.error ? [plans.error] : [],
    exitCode: plans.error ? 3 : 0,
  };
}

module.exports = { collectSessionFacts };
