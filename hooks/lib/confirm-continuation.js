"use strict";
// hooks/lib/confirm-continuation.js — which plan stages a turn presented (#2650, #2729), for the
// Stop hook (stop-confirm-plan-guard.js), plus the wording it and confirm-checkpoint.js share.
// A stage is presented when the turn's last assistant entry is text only and its last text block
// closes on a run of plan-link lines holding the stage's line, while the stage is unapproved and
// its gate is not OFF. The Stop hook turns a presentation into a receipt
// (hooks/lib/presentation-receipt.js); confirm-checkpoint never reads the transcript.

const fs = require("fs");
const PL = require("./plan-link");
const { inTrailingLinkRun } = require("./plan-link-turn-check");
const { approvalArtifactPath } = require("./presentation-receipt");
const { planGateState } = require("./confirm-gate/plan-gate");
const { stepForSuffix } = require("../workflow-state/plan-stage-table");
const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../../bin/workflow/lib/next-step/gate-line");
const { withConvLang } = require("./conv-lang");

function textOnlyAnchor(tail) {
  const t = tail || {};
  const anchor = t.lastTextEntry;
  if (!anchor || typeof anchor.uuid !== "string" || !anchor.uuid || anchor !== t.lastAssistantEntry) return null;
  const c = anchor.message && anchor.message.content;
  if (!Array.isArray(c) || c.some((it) => it && it.type === "tool_use")) return null;
  return anchor;
}

// gateForFrom(timeoutMsFor) -> stage -> gate, probing each stage at most once within the budget.
function gateForFrom(timeoutMsFor) {
  const memo = {};
  return (stage) => {
    if (!(stage in memo)) {
      const timeoutMs = typeof timeoutMsFor === "function" ? timeoutMsFor() : NEXT_STEP_GATE_PROBE_TIMEOUT_MS;
      memo[stage] = planGateState(stage, { timeoutMs });
    }
    return memo[stage];
  };
}

// presentedStagesOfText({sid, lastText, stages, plansDir, timeoutMsFor, gateFor, linkFor}) -> [{stage,
// absPath, reason, receiptLink, contentSha}] among `stages`, judging `lastText` as the turn's last
// text block. gateFor (stage -> gate) and linkFor (absPath -> link) let the caller share one probe
// per stage and one git lookup per file; without gateFor the gate is probed within timeoutMsFor().
// receiptLink is null when the plan has no link that may stand for it (not published).
function presentedStagesOfText({ sid, lastText, stages, plansDir, timeoutMsFor, gateFor, linkFor } = {}) {
  if (typeof lastText !== "string" || !lastText || !Array.isArray(stages)) return [];
  const gate = typeof gateFor === "function" ? gateFor : gateForFrom(timeoutMsFor);
  const linkOf = typeof linkFor === "function" ? linkFor : (p) => PL.linkForFile(p, plansDir ? { plansDir } : {});
  const { checkPlanApproval } = require("../workflow-state/plan-approval-check");
  const { computeContentSha } = require("../workflow-state/completion-approval");
  const out = [];
  for (const stage of PL.STAGES) {
    if (!stages.includes(stage)) continue;
    const absPath = approvalArtifactPath(sid, stage);
    if (!absPath || !fs.existsSync(absPath)) continue;
    const link = linkOf(absPath);
    if (!inTrailingLinkRun(lastText, Object.assign({ stage }, link))) continue;
    const g = gate(stage);
    if (g === "OFF") continue;
    if (checkPlanApproval(sid, stepForSuffix(stage), { gate: g }).verdict !== "unapproved") continue;
    out.push({ stage, absPath, reason: link.reason || null, receiptLink: PL.receiptLinkOf(link), contentSha: computeContentSha(absPath) });
  }
  return out;
}

// presentedStages({sid, tail, plansDir, timeoutMsFor, gateFor, linkFor}): presentedStagesOfText over
// every stage, for a tail whose last assistant entry is its text-only last text entry.
function presentedStages({ sid, tail, plansDir, timeoutMsFor, gateFor, linkFor } = {}) {
  if (!textOnlyAnchor(tail)) return [];
  return presentedStagesOfText({ sid, lastText: tail.lastTextBlock, stages: PL.STAGES, plansDir, timeoutMsFor, gateFor, linkFor });
}

// continuationStage(presented, currentStage) -> the stage the Stop hook asks to echo, or null:
// among the stages that have a receipt link, the current step's stage, else the only one.
function continuationStage(presented, currentStage) {
  const linked = (Array.isArray(presented) ? presented : []).filter((p) => p && p.receiptLink);
  if (linked.some((p) => p.stage === currentStage)) return currentStage;
  return linked.length === 1 ? linked[0].stage : null;
}

function continueReason(stage) {
  const S = String(stage).toUpperCase();
  return withConvLang(`[confirm-plan] continue: as your next message, emit only echo "<<WORKFLOW_CONFIRM_${S}: {one-line summary}>>" — the approval dialog follows.`);
}

const CAUSE_TEXT = {
  "not-last": "its plan-link line is followed by other text, so the line did not close the turn",
  unpublished: "it is not published yet although this environment can publish it — rewrite it through the plan-sync path (the Write or Edit tool on the plan file) and present it only once its URL line is available",
  "no-receipt": "no presentation of it is on record",
  "unreadable-receipt": "its presentation receipt cannot be read",
  path: "the presented file is not the plan being approved",
  link: "the link shown then differs from the plan's link now",
  content: "the plan changed after it was presented",
  "unverifiable-session": "the session cannot be identified",
  "unverifiable-artifact": "the plan file being approved cannot be found",
  "unverifiable-link": "the plan's link cannot be resolved",
  "unverifiable-content": "the plan file cannot be read",
  "check-threw": "the presentation check could not complete",
};

// presentAgainReason(stage, cause) -> the Stop block and the CONFIRM deny reason, shared.
function presentAgainReason(stage, cause) {
  const why = CAUSE_TEXT[cause] || CAUSE_TEXT["no-receipt"];
  return withConvLang(`[confirm-plan] present the ${stage} plan again (${cause}): ${why}. ` +
    `Run ${PL.PLAN_LINK_COMMAND.replace("<stage>", stage)}, end the last text block of the turn with its output as-is, ` +
    "with no text after the line, and close the turn. When the turn end then returns \"[confirm-plan] continue:\", " +
    "emit only the CONFIRM echo as your next message; without that prompt, echo the CONFIRM after the user's reply.");
}

module.exports = { presentedStages, presentedStagesOfText, continuationStage, continueReason, presentAgainReason };
