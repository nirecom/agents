"use strict";
// SSOT for "is this plan step permitted to be skipped?" (#1644): the *_NOT_NEEDED
// sentinel door (hooks/gate-plan-skip-sentinel.js) and the CLI's `--advance --status
// skipped` door both read this module so the rule cannot drift between them.
// The doors differ only in how much the ENVIRONMENT is trusted:
//   isSkipAllowedForSentinelPath — reads process.env; the hook's env is inherited
//     from Claude Code and cannot be forged by a model-issued command prefix.
//   isSkipAllowedForCliPath — reads the config FILE only; a Bash-spawned process
//     could carry a model-issued `CONFIRM_TESTS=off` prefix.
// The config-file-only why is owned by the isConfirmOffForStageFromFile comment
// in hooks/lib/plan-confirm-flag.js.

const { getConfirmFlagName, isConfirmOffForStageFromFile } = require("../lib/plan-confirm-flag");

// Exact (case-insensitive) literals, matching hooks/gate-plan-skip-sentinel.js.
const OFF_LITERALS = new Set(["off"]);

// step → CONFIRM_* stage suffix. A step absent from this map has no
// auto-approval route on either door and can never be skipped through them.
const STAGE_FOR_STEP = {
  outline: "outline",
  detail: "detail",
  write_tests: "tests",
};

// Steps whose skip may also be authorized by a recorded orchestrator judgment
// (#1286). Kept separate from STAGE_FOR_STEP: the recorded-verdict axis is a
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

// Sentinel-door CONFIRM_* read. Exported so gate-plan-skip-sentinel.js can keep
// its two distinct allow wordings while both branches still come from here.
function isConfirmOffForStepSentinel(step) {
  const stage = STAGE_FOR_STEP[step];
  if (!stage) return false;
  const flagName = getConfirmFlagName(stage);
  if (!flagName) return false;
  const raw = process.env[flagName];
  return raw != null && OFF_LITERALS.has(String(raw).trim().toLowerCase());
}

// CLI-door CONFIRM_* read. Config file only — see the header comment.
function isConfirmOffForStepCli(step) {
  const stage = STAGE_FOR_STEP[step];
  if (!stage) return false;
  return isConfirmOffForStageFromFile(stage) === true;
}

function isSkipAllowedForSentinelPath(sessionId, step) {
  if (hasRecordedSkipJudgment(sessionId, step)) return true;
  // The env read is spelled out here (rather than only in the helper) so the
  // trust boundary is visible at the door itself: process.env is admissible on
  // the sentinel path and inadmissible on the CLI path below.
  const stage = STAGE_FOR_STEP[step];
  if (!stage) return false;
  const flagName = getConfirmFlagName(stage);
  if (!flagName) return false;
  const raw = process.env[flagName];
  return raw != null && OFF_LITERALS.has(String(raw).trim().toLowerCase());
}

function isSkipAllowedForCliPath(sessionId, step) {
  if (hasRecordedSkipJudgment(sessionId, step)) return true;
  return isConfirmOffForStepCli(step) === true;
}

module.exports = {
  STAGE_FOR_STEP,
  RECORDED_JUDGMENT_STEPS,
  hasRecordedSkipJudgment,
  isConfirmOffForStepSentinel,
  isConfirmOffForStepCli,
  isSkipAllowedForSentinelPath,
  isSkipAllowedForCliPath,
};
