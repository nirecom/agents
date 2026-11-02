"use strict";
// SSOT for "is this plan step permitted to be skipped?" (#1644): the *_NOT_NEEDED
// sentinel door (hooks/gate-plan-skip-sentinel.js) and the CLI's `--advance --status
// skipped` door both read this module so the rule cannot drift between them.
// The doors differ only in how much the ENVIRONMENT is trusted:
//   isSkipAllowedForSentinelPath — reads process.env; the hook's env is inherited
//     from Claude Code and cannot be forged by a model-issued command prefix.
//   isSkipAllowedForCliPath — reads the config FILE only; a Bash-spawned process
//     could carry a model-issued `CONFIRM_TESTS=off` prefix.
// The config-file-only why is owned by the isConfirmFlagOffFromFile comment
// in hooks/lib/plan-confirm-flag.js.

const { isConfirmFlagOffFromFile } = require("../lib/plan-confirm-flag");
const { PLAN_STEP_TABLE } = require("./plan-step-table");

// Exact (case-insensitive) literals, matching hooks/gate-plan-skip-sentinel.js.
const OFF_LITERALS = new Set(["off"]);

const OFF_WAIVABLE_ROWS = Object.entries(PLAN_STEP_TABLE).filter(([, row]) => row.offWaivable === true);

// step → the CONFIRM_* flag that may waive it. Built from the plan steps whose flag may waive the
// gate (clarify_intent's may not) plus write_tests, which has no plan artifact. A step absent from
// this map has no auto-approval route on either door and can never be skipped through them.
const CONFIRM_FLAG_OF_STEP = Object.freeze(Object.assign(
  Object.fromEntries(OFF_WAIVABLE_ROWS.map(([step, row]) => [step, row.confirmFlag])),
  { write_tests: "CONFIRM_TESTS" },
));

// Plan steps read their flag from the config FILE only, on both doors (#2726/#2729: an exported
// CONFIRM_OUTLINE / CONFIRM_DETAIL is ignored); write_tests still reads process.env on the
// sentinel door.
const FILE_ONLY_STEPS = new Set(OFF_WAIVABLE_ROWS.map(([step]) => step));

// Steps whose skip may also be authorized by a recorded orchestrator judgment
// (#1286). Kept separate from CONFIRM_FLAG_OF_STEP: the recorded-verdict axis is a
// state fact, the CONFIRM_* axis is a configuration fact.
const RECORDED_JUDGMENT_STEPS = ["outline", "detail"];

// hasValidSkipJudgment lives behind the workflow-state barrel; required lazily so
// this module can be pulled in from a hook that loads before the barrel is ready.
// Fail-closed: an unreadable judgment never authorizes a skip.
function hasRecordedSkipJudgment(sessionId, step) {
  if (!sessionId) return false;
  if (RECORDED_JUDGMENT_STEPS.indexOf(step) === -1) return false;
  try {
    const { hasValidSkipJudgment } = require("../workflow-state");
    if (typeof hasValidSkipJudgment !== "function") return false;
    return hasValidSkipJudgment(sessionId, step) === true;
  } catch (_) {
    return false;
  }
}

function flagOf(step) {
  return Object.prototype.hasOwnProperty.call(CONFIRM_FLAG_OF_STEP, step) ? CONFIRM_FLAG_OF_STEP[step] : null;
}

// Sentinel-door CONFIRM_* read. Exported so gate-plan-skip-sentinel.js can keep
// its two distinct allow wordings while both branches still come from here.
function isConfirmOffForStepSentinel(step) {
  const flagName = flagOf(step);
  if (!flagName) return false;
  if (FILE_ONLY_STEPS.has(step)) return isConfirmFlagOffFromFile(flagName) === true;
  const raw = process.env[flagName];
  return raw != null && OFF_LITERALS.has(String(raw).trim().toLowerCase());
}

// CLI-door CONFIRM_* read. Config file only — see the header comment.
function isConfirmOffForStepCli(step) {
  const flagName = flagOf(step);
  if (!flagName) return false;
  return isConfirmFlagOffFromFile(flagName) === true;
}

function isSkipAllowedForSentinelPath(sessionId, step) {
  if (hasRecordedSkipJudgment(sessionId, step)) return true;
  // process.env is admissible on the sentinel path for write_tests only; plan
  // steps read the config file on both doors.
  return isConfirmOffForStepSentinel(step) === true;
}

function isSkipAllowedForCliPath(sessionId, step) {
  if (hasRecordedSkipJudgment(sessionId, step)) return true;
  return isConfirmOffForStepCli(step) === true;
}

module.exports = {
  CONFIRM_FLAG_OF_STEP,
  FILE_ONLY_STEPS,
  RECORDED_JUDGMENT_STEPS,
  hasRecordedSkipJudgment,
  isConfirmOffForStepSentinel,
  isConfirmOffForStepCli,
  isSkipAllowedForSentinelPath,
  isSkipAllowedForCliPath,
};
