"use strict";
// hooks/lib/confirm-continuation.js — which plan artifacts a turn presented (#2650, #2729), for the
// Stop hook (stop-confirm-plan-guard.js), plus the wording it and confirm-checkpoint.js share.
// A plan is presented when the turn's last assistant entry is text only and its last text block
// closes on a run of plan-link lines holding the plan's line, while its step is unapproved and the
// step's gate is not OFF. The Stop hook turns a presentation into a receipt
// (hooks/lib/presentation-receipt.js); confirm-checkpoint reads the transcript only to recover a
// receipt a killed Stop left unwritten (confirm-checkpoint/receipt-recovery.js, #2936).
// The presented list and the wording are keyed by the plan artifact name; the gate lookup is keyed
// by the step (#2820), so each artifact is converted once with stepForSuffix.

const fs = require("fs");
const PL = require("./plan-link");
const { inTrailingLinkRun } = require("./plan-link-turn-check");
const { approvalArtifactPath } = require("./presentation-receipt");
const { planGateState } = require("./confirm-gate/plan-gate");
const { PLAN_ARTIFACT_NAMES, stepForSuffix } = require("../workflow-state/plan-step-table");
const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../../bin/workflow/lib/next-step/gate-line");
const { withConvLang } = require("./conv-lang");
const { NO_RECEIPT_HINT } = require("./no-receipt-hint");

function textOnlyAnchor(tail) {
  const t = tail || {};
  const anchor = t.lastTextEntry;
  if (!anchor || typeof anchor.uuid !== "string" || !anchor.uuid || anchor !== t.lastAssistantEntry) return null;
  const c = anchor.message && anchor.message.content;
  if (!Array.isArray(c) || c.some((it) => it && it.type === "tool_use")) return null;
  return anchor;
}

// gateForFrom(timeoutMsFor) -> step -> gate, probing each step at most once within the budget.
function gateForFrom(timeoutMsFor) {
  const memo = {};
  return (step) => {
    if (!(step in memo)) {
      const timeoutMs = typeof timeoutMsFor === "function" ? timeoutMsFor() : NEXT_STEP_GATE_PROBE_TIMEOUT_MS;
      memo[step] = planGateState(step, { timeoutMs });
    }
    return memo[step];
  };
}

// presentedArtifactsOfText({sid, lastText, stages, plansDir, timeoutMsFor, gateFor, linkFor}) ->
// [{stage, absPath, reason, receiptLink, contentSha}] among `stages` (plan artifact names; `stage` in
// each entry is the artifact name too), judging `lastText` as the turn's last text block. gateFor
// (step -> gate) and linkFor (absPath -> link) let the caller share one probe per step and one git
// lookup per file; without gateFor the gate is probed within timeoutMsFor().
// receiptLink is null when the plan has no link that may stand for it (not published).
function presentedArtifactsOfText({ sid, lastText, stages, plansDir, timeoutMsFor, gateFor, linkFor } = {}) {
  if (typeof lastText !== "string" || !lastText || !Array.isArray(stages)) return [];
  const gate = typeof gateFor === "function" ? gateFor : gateForFrom(timeoutMsFor);
  const linkOf = typeof linkFor === "function" ? linkFor : (p) => PL.linkForFile(p, plansDir ? { plansDir } : {});
  const { checkPlanApproval } = require("../workflow-state/plan-approval-check");
  const { computeContentSha } = require("../workflow-state/completion-approval");
  const out = [];
  for (const artifact of PLAN_ARTIFACT_NAMES) {
    if (!stages.includes(artifact)) continue;
    const absPath = approvalArtifactPath(sid, artifact);
    if (!absPath || !fs.existsSync(absPath)) continue;
    const link = linkOf(absPath);
    if (!inTrailingLinkRun(lastText, Object.assign({ stage: artifact }, link))) continue;
    const step = stepForSuffix(artifact);
    const g = gate(step);
    if (g === "OFF") continue;
    if (checkPlanApproval(sid, step, { gate: g }).verdict !== "unapproved") continue;
    out.push({ stage: artifact, absPath, reason: link.reason || null, receiptLink: PL.receiptLinkOf(link), contentSha: computeContentSha(absPath) });
  }
  return out;
}

// presentedArtifacts({sid, tail, plansDir, timeoutMsFor, gateFor, linkFor}): presentedArtifactsOfText
// over every plan artifact, for a tail whose last assistant entry is its text-only last text entry.
function presentedArtifacts({ sid, tail, plansDir, timeoutMsFor, gateFor, linkFor } = {}) {
  if (!textOnlyAnchor(tail)) return [];
  return presentedArtifactsOfText({ sid, lastText: tail.lastTextBlock, stages: PLAN_ARTIFACT_NAMES, plansDir, timeoutMsFor, gateFor, linkFor });
}

// continuationArtifact(presented, currentArtifact) -> the plan artifact name the Stop hook asks to
// echo, or null: among the plans that have a receipt link, the current step's, else the only one.
function continuationArtifact(presented, currentArtifact) {
  const linked = (Array.isArray(presented) ? presented : []).filter((p) => p && p.receiptLink);
  if (linked.some((p) => p.stage === currentArtifact)) return currentArtifact;
  return linked.length === 1 ? linked[0].stage : null;
}

function continueReason(artifact) {
  const S = String(artifact).toUpperCase();
  return withConvLang(`[confirm-plan] continue: as your next message, emit only echo "<<WORKFLOW_CONFIRM_${S}: {one-line summary}>>" — the presentation is recorded, so the approval dialog follows.`);
}

const CAUSE_TEXT = {
  "not-last": "its plan-link line is followed by other text, so the line did not close the turn",
  unpublished: "it is not published yet although this environment can publish it — rewrite it through the plan-sync path (the Write or Edit tool on the plan file) and present it only once its URL line is available",
  "no-receipt": "no presentation of it is on record and the previous turn does not show one; " + NO_RECEIPT_HINT,
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

// presentAgainReason(artifact, cause) -> the Stop block and the CONFIRM deny reason, shared.
function presentAgainReason(artifact, cause) {
  const why = CAUSE_TEXT[cause] || CAUSE_TEXT["no-receipt"];
  return withConvLang(`[confirm-plan] present the ${artifact} plan again (${cause}): ${why}. ` +
    `Run ${PL.PLAN_LINK_COMMAND.replace("<step>", stepForSuffix(artifact))}, end the last text block of the turn with its output as-is, ` +
    "with no text after the line, and close the turn. When the turn end then returns \"[confirm-plan] continue:\", " +
    "emit only the CONFIRM echo as your next message; without that prompt, echo the CONFIRM after the user's reply.");
}

module.exports = { presentedArtifacts, presentedArtifactsOfText, continuationArtifact, continueReason, presentAgainReason };
