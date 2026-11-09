"use strict";
// hooks/stop-confirm-plan-guard/settle.js — how the Stop guard ends a turn it did not block: the
// presentation receipts it writes, the undecidable tail's partial record (#2771), the notice for a
// plan left unrecorded, and the one continue of the current plan (#2729). Moved out of the entry
// unchanged (#2936).

const fs = require("fs");
const { planRelintReason } = require("../lib/presentation-turn/block-reasons");
const { PROBE_RESERVE_MS, probesFor } = require("../lib/presentation-turn");
const { PLAN_ARTIFACT_NAMES, stepForSuffix } = require("../workflow-state/plan-step-table");

// recordReceipts(sid, presented, anchorUuid, carryMark) -> {written, failed}: one receipt per presented
// plan that has a receipt link; a plan that cannot be written loses its stale receipt. presented and
// failed hold plan artifact names; the receipt is keyed by the step.
function recordReceipts(sid, presented, anchorUuid, carryMark) {
  const PR = require("../lib/presentation-receipt");
  const written = [];
  const failed = [];
  for (const p of presented) {
    const step = stepForSuffix(p.stage);
    const ok = p.receiptLink && PR.writeReceipt(sid, step, {
      absPath: p.absPath, link: p.receiptLink, contentSha: p.contentSha, anchorUuid, carryMark,
    });
    if (ok) {
      written.push(p);
    } else {
      PR.discardReceipt(sid, step);
      failed.push(p.stage);
    }
  }
  return { written, failed };
}

function appendNotice(sid, detail) {
  try {
    require("../lib/supervisor-state-writer").appendFinding(sid, {
      categories: ["workflow"], severity: "notice", detail: `stop-confirm-plan-guard: ${detail}`, reporter: "stop-confirm-plan-guard",
    });
  } catch (_) { /* the finding is advisory */ }
}

// Under stop_hook_active a block is not emitted, so a Gap 5 or unpublished hit is left for the supervisor.
function recordUnblocked(sid, block) {
  if (!block || (block.kind !== "not-last" && block.kind !== "unpublished")) return;
  appendNotice(sid, `${block.kind} presentation passed unblocked (stop_hook_active); no receipt recorded for this turn; earlier receipts kept`);
}

// recordUndecidable({sid, input, tail, markers, deadline, active, probes}) -> {unrecorded, written}:
// unrecorded is the failed writes plus every plan whose step's gate is not OFF that may have been
// presented but got no receipt; written is the presented plans recorded. Only
// a plan the real final message (last_assistant_message) closes on is recorded: with the anchored
// entry's uuid when an anchored text entry also presents it, otherwise with anchorUuid "" (no anchor,
// or final-only). A plan only the anchored text presents stays unrecorded. A plan that
// is over HARD, violates PLAN_LANG or is unpublished is left unrecorded with its earlier receipt
// untouched, as the decidable path would block it. probes defaults to probesFor(deadline); a caller
// may pass its own {plansDir, gateFor, linkFor} to observe the step keys gateFor receives.
function recordUndecidable({ sid, input, tail, markers, deadline, active, probes: given }) {
  const UD = require("./undecidable");
  const CC = require("../lib/confirm-continuation");
  const maybe = UD.mayHavePresented({ sid, markers, input });
  if (deadline - Date.now() < PROBE_RESERVE_MS) return { unrecorded: maybe, written: [] };
  const probes = given || probesFor(deadline);
  const anchored = UD.anchoredTailOf(tail);
  const inFinal = CC.presentedArtifactsOfText(Object.assign({ sid, lastText: input.last_assistant_message, stages: PLAN_ARTIFACT_NAMES }, probes));
  const fromTail = anchored ? CC.presentedArtifacts(Object.assign({ sid, tail: anchored }, probes)) : [];
  const finalStages = inFinal.map((p) => p.stage);
  const tailStages = fromTail.map((p) => p.stage);
  const presented = [...fromTail.filter((p) => finalStages.includes(p.stage)), ...inFinal.filter((p) => !tailStages.includes(p.stage))];
  const relintBlocked = presented.filter((p) => planRelintReason(sid, p.stage)).map((p) => p.stage);
  const unpublished = presented.filter((p) => !p.receiptLink && !relintBlocked.includes(p.stage)).map((p) => p.stage);
  const recordable = presented.filter((p) => !relintBlocked.includes(p.stage) && !unpublished.includes(p.stage));
  const both = recordReceipts(sid, recordable.filter((p) => tailStages.includes(p.stage)), anchored ? anchored.lastTextEntry.uuid : "", active);
  const finalOnly = recordReceipts(sid, recordable.filter((p) => !tailStages.includes(p.stage)), "", active);
  const failed = [...both.failed, ...finalOnly.failed];
  const written = [...both.written, ...finalOnly.written];
  const writtenStages = written.map((p) => p.stage);
  // mayHavePresented answers plan artifact names; the gate is keyed by the step.
  const unwritten = maybe.filter((stage) => !writtenStages.includes(stage) && probes.gateFor(stepForSuffix(stage)) !== "OFF");
  return { unrecorded: [...new Set([...relintBlocked, ...unpublished, ...failed, ...unwritten])], written };
}

function mayHavePresented(sid, markers, input) {
  try {
    return require("./undecidable").mayHavePresented({ sid, markers, input });
  } catch (_) {
    return [];
  }
}

function emitBlock(reason, systemMessage) {
  process.stdout.write(JSON.stringify(Object.assign({ decision: "block", reason }, systemMessage ? { systemMessage } : {})));
  process.exit(2);
}

// The recorded step's plan artifact name: that of the first plan step not settled. Unlike
// resolveCurrentEffectiveStep it does not re-judge approvals, so a re-presented earlier plan neither
// moves it nor costs a gate probe.
function currentArtifact(sid) {
  try {
    const { readState, isSettledStatus } = require("../workflow-state/state-io");
    const { effectiveStatus } = require("../workflow-state/effective-state");
    const { PLAN_STEP_TABLE } = require("../workflow-state/plan-step-table");
    const state = readState(sid);
    if (!state || !state.steps) return null;
    const profile = require("../workflow-state/session-profile").resolveSessionProfile(state, sid);
    for (const [step, row] of Object.entries(PLAN_STEP_TABLE)) {
      const entry = state.steps[step];
      if (!isSettledStatus(effectiveStatus(step, (entry && entry.status) || "pending", profile))) return row.suffix;
    }
    return null;
  } catch (_) {
    return null;
  }
}

// settleStop: notify on every Stop that leaves a plan unrecorded, spend the markers outside
// stop_hook_active, then continue the current plan once (the receipt's continuedAt caps it). Order:
// receipts written -> mark checked -> mark written -> continue with the notice. Every other exit is
// finish(), which still carries the notice. unrecorded / written / the continued plan are plan
// artifact names; the receipt API takes stepForSuffix of them. undecidable ({input, tail}) gates the
// continue on tailAllowsContinue.
function settleStop(sid, active, { unrecorded, written }, TM, undecidable, deadline) {
  const UD = require("./undecidable");
  const notice = unrecorded.length > 0 ? UD.noticeFor(unrecorded) : "";
  if (notice) appendNotice(sid, `presentation receipt not recorded for ${unrecorded.join(", ")}; the user was notified`);
  const finish = () => {
    if (notice) {
      try { fs.writeSync(1, JSON.stringify({ systemMessage: notice })); } catch (_) { /* the notice is advisory */ }
    }
    process.exit(0);
  };
  if (!active) TM.readAndDeleteTurnMarkers(sid);
  const CC = require("../lib/confirm-continuation");
  const PR = require("../lib/presentation-receipt");
  const current = currentArtifact(sid);
  // A current plan that failed to record must not hand the continue to another written plan.
  let artifact = unrecorded.includes(current) ? null : CC.continuationArtifact(written, current);
  if (artifact && undecidable && !UD.tailAllowsContinue(undecidable.tail, undecidable.input, deadline)) artifact = null;
  if (!artifact) finish();
  const step = stepForSuffix(artifact);
  const receipt = PR.readReceipt(sid, step);
  if (receipt.ok && PR.isContinued(receipt.receipt)) finish();
  if (!PR.markContinued(sid, step)) finish();
  emitBlock(CC.continueReason(artifact), notice);
}

module.exports = { recordReceipts, recordUndecidable, recordUnblocked, mayHavePresented, settleStop, emitBlock };
