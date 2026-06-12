"use strict";
// Handles CONFIRM_<STAGE> sentinels emitted by clarify-intent / make-outline-plan /
// make-detail-plan after the user clicks Allow on the permission dialog.
//
// The CONFIRM sentinel itself does NOT mark a workflow step (it is a confirmation
// gate, not a step-completion marker). Its purpose here is to push a next-step
// hint into the LLM's next inference via the workflow-mark.js additionalContext
// channel — so the workflow continues even when the LLM emitted only the CONFIRM
// sentinel without co-emitting the follow-up tool calls.

const {
  CONFIRM_INTENT_RE_DQ,
  CONFIRM_OUTLINE_RE_DQ,
  CONFIRM_DETAIL_RE_DQ,
} = require("../lib/sentinel-patterns");
const { confirmNextStepHint } = require("../lib/workflow-state");

function handle(ctx) {
  const { cmd, pushMessage } = ctx;
  let stage = null;
  if (CONFIRM_INTENT_RE_DQ.test(cmd)) stage = "intent";
  else if (CONFIRM_OUTLINE_RE_DQ.test(cmd)) stage = "outline";
  else if (CONFIRM_DETAIL_RE_DQ.test(cmd)) stage = "detail";
  if (!stage) return false;

  const hint = confirmNextStepHint(stage);
  if (hint) pushMessage(hint);
  return true;
}

module.exports = { handle };
