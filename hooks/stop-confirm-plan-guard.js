#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan protocol. Each check returns a block reason or
// null; the first reason found blocks (layer 2, plan-link, close-on-link, unpublished, plan-lang).
// Layer 2 (#2278): a CONFIRM echo in the last assistant entry needs a PLAN_LANG-clean plan and a
// stage-valid follow-up tool_use. Plan-link: a turn that wrote a plan shows its link line — in the
// last text block when the stage's gate is ON, anywhere in the turn when it is OFF.
// Presentation (#2729): a turn the hook lets through that closes on unapproved stages' link lines
// gets a presentation receipt per stage (hooks/lib/presentation-receipt.js) and the current stage is
// continued once for the CONFIRM echo; a blocked turn records none and keeps earlier receipts. An
// undecidable tail (#2771) records what the final message confirms and notifies on every Stop.
// Reason prefixes and the marker contract: docs/architecture/claude-code/settings.md.
"use strict";

const fs = require("fs");
const path = require("path");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
const { firstBlock, planLangReason, PLAN_STAGES } = require("./stop-confirm-plan-guard/block-reasons");

const STOP_BUDGET_MS = 4000;
const PROBE_RESERVE_MS = 500;

// probesFor(deadline) -> {plansDir, gateFor, linkFor}: one gate probe per stage within the budget (a
// spent budget reads ERROR, treated as ON) and one git lookup per plan file, shared by every check.
function probesFor(deadline) {
  const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
  const { planGateState } = require("./lib/confirm-gate/plan-gate");
  const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../bin/workflow/lib/next-step/gate-line");
  const gates = {};
  const gateFor = (stage) => {
    if (!(stage in gates)) {
      const timeoutMs = Math.min(NEXT_STEP_GATE_PROBE_TIMEOUT_MS, deadline - Date.now() - PROBE_RESERVE_MS);
      gates[stage] = planGateState(stage, { timeoutMs });
    }
    return gates[stage];
  };
  const plansDir = getWorkflowPlansDir();
  const links = new Map();
  const linkFor = (absPath) => {
    const key = path.resolve(absPath);
    if (!links.has(key)) links.set(key, require("./lib/plan-link").linkForFile(absPath, { plansDir }));
    return links.get(key);
  };
  return { plansDir, gateFor, linkFor };
}

// recordReceipts(sid, presented, anchorUuid) -> {written, failed}: one receipt per presented stage
// that has a receipt link; a stage that cannot be written loses its stale receipt.
function recordReceipts(sid, presented, anchorUuid) {
  const PR = require("./lib/presentation-receipt");
  const written = [];
  const failed = [];
  for (const p of presented) {
    const ok = p.receiptLink && PR.writeReceipt(sid, p.stage, {
      absPath: p.absPath, link: p.receiptLink, contentSha: p.contentSha, anchorUuid,
    });
    if (ok) {
      written.push(p);
    } else {
      PR.discardReceipt(sid, p.stage);
      failed.push(p.stage);
    }
  }
  return { written, failed };
}

// judgeTurn(ctx) -> {block, written}: a block leaves every receipt as it is.
function judgeTurn(ctx) {
  const CC = require("./lib/confirm-continuation");
  const presented = CC.presentedStages({ sid: ctx.sid, tail: ctx.tail, plansDir: ctx.plansDir, gateFor: ctx.gateFor, linkFor: ctx.linkFor });
  const block = firstBlock(ctx, presented);
  if (block) return { block, written: [] };
  const anchorUuid = ctx.tail.lastTextEntry ? ctx.tail.lastTextEntry.uuid : "";
  return { block: null, written: recordReceipts(ctx.sid, presented, anchorUuid).written };
}

function appendNotice(sid, detail) {
  try {
    require("./lib/supervisor-state-writer").appendFinding(sid, {
      categories: ["workflow"], severity: "notice", detail: `stop-confirm-plan-guard: ${detail}`, reporter: "stop-confirm-plan-guard",
    });
  } catch (_) { /* the finding is advisory */ }
}

// Under stop_hook_active nothing is blocked, so a Gap 5 or unpublished hit is left for the supervisor.
function recordUnblocked(sid, block) {
  if (!block || (block.kind !== "not-last" && block.kind !== "unpublished")) return;
  appendNotice(sid, `${block.kind} presentation passed unblocked (stop_hook_active); no receipt recorded for this turn; earlier receipts kept`);
}

// recordUndecidable({sid, input, tail, markers, deadline}) -> the stages left unrecorded: the failed
// writes plus every stage whose gate is not OFF that may have been presented but got no receipt. Only
// a stage the real final message (last_assistant_message) closes on is recorded: with the anchored
// entry's uuid when an anchored text entry also presents it, otherwise with anchorUuid "" (no anchor,
// or final-only). A stage only the anchored text presents stays unrecorded. A stage whose plan
// violates PLAN_LANG or is unpublished is left unrecorded with its earlier receipt untouched, as the
// decidable path would block it.
function recordUndecidable({ sid, input, tail, markers, deadline }) {
  const UD = require("./stop-confirm-plan-guard/undecidable");
  const CC = require("./lib/confirm-continuation");
  const maybe = UD.mayHavePresented({ sid, markers, input });
  if (deadline - Date.now() < PROBE_RESERVE_MS) return maybe;
  const probes = probesFor(deadline);
  const anchored = UD.anchoredTailOf(tail);
  const inFinal = CC.presentedStagesOfText(Object.assign({ sid, lastText: input.last_assistant_message, stages: PLAN_STAGES }, probes));
  const fromTail = anchored ? CC.presentedStages(Object.assign({ sid, tail: anchored }, probes)) : [];
  const finalStages = inFinal.map((p) => p.stage);
  const tailStages = fromTail.map((p) => p.stage);
  const presented = [...fromTail.filter((p) => finalStages.includes(p.stage)), ...inFinal.filter((p) => !tailStages.includes(p.stage))];
  const langBlocked = presented.filter((p) => planLangReason(sid, p.stage)).map((p) => p.stage);
  const unpublished = presented.filter((p) => !p.receiptLink && !langBlocked.includes(p.stage)).map((p) => p.stage);
  const recordable = presented.filter((p) => !langBlocked.includes(p.stage) && !unpublished.includes(p.stage));
  const both = recordReceipts(sid, recordable.filter((p) => tailStages.includes(p.stage)), anchored ? anchored.lastTextEntry.uuid : "");
  const finalOnly = recordReceipts(sid, recordable.filter((p) => !tailStages.includes(p.stage)), "");
  const failed = [...both.failed, ...finalOnly.failed];
  const writtenStages = [...both.written, ...finalOnly.written].map((p) => p.stage);
  const unwritten = maybe.filter((stage) => !writtenStages.includes(stage) && probes.gateFor(stage) !== "OFF");
  return [...new Set([...langBlocked, ...unpublished, ...failed, ...unwritten])];
}

function mayHavePresented(sid, markers, input) {
  try {
    return require("./stop-confirm-plan-guard/undecidable").mayHavePresented({ sid, markers, input });
  } catch (_) {
    return [];
  }
}

// settleUnjudged exits 0 without a block: it tells the user on every Stop that leaves a stage
// unrecorded (no block, so this cannot loop), then spends the markers outside stop_hook_active.
function settleUnjudged(sid, active, unrecorded, TM) {
  if (unrecorded.length > 0) {
    try {
      fs.writeSync(1, JSON.stringify({ systemMessage: require("./stop-confirm-plan-guard/undecidable").noticeFor(unrecorded) }));
    } catch (_) { /* the notice is advisory */ }
    appendNotice(sid, `presentation receipt not recorded for ${unrecorded.join(", ")}; the user was notified`);
  }
  if (!active) TM.readAndDeleteTurnMarkers(sid);
  process.exit(0);
}

// The recorded step's stage: the first plan stage not settled. Unlike resolveCurrentEffectiveStep it
// does not re-judge approvals, so a re-presented earlier plan neither moves it nor costs a gate probe.
function currentStage(sid) {
  try {
    const { readState, isSettledStatus } = require("./workflow-state/state-io");
    const { effectiveStatus } = require("./workflow-state/effective-state");
    const { PLAN_STAGE_TABLE } = require("./workflow-state/plan-stage-table");
    const state = readState(sid);
    if (!state || !state.steps) return null;
    const profile = require("./workflow-state/session-profile").resolveSessionProfile(state, sid);
    for (const [step, row] of Object.entries(PLAN_STAGE_TABLE)) {
      const entry = state.steps[step];
      if (!isSettledStatus(effectiveStatus(step, (entry && entry.status) || "pending", profile))) return row.suffix;
    }
    return null;
  } catch (_) {
    return null;
  }
}

function emitBlock(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(2);
}

// readTail(input) -> {kind: "ok"|"undecidable", tail} | {kind: "none", tail?}: "none" is a tail the
// hook cannot read or whose last assistant entry is malformed, so no receipt is inferred from it.
function readTail(input) {
  try {
    const { readTurnTail, parseLines } = require("./lib/transcript-reader");
    const tail = readTurnTail({ input });
    tail.entries = parseLines(tail.lines);
    const content = tail.lastAssistantEntry && tail.lastAssistantEntry.message && tail.lastAssistantEntry.message.content;
    if (tail.lastAssistantEntry && !Array.isArray(content)) return { kind: "none", tail };
    return { kind: tail.undecidable ? "undecidable" : "ok", tail };
  } catch (_) {
    return { kind: "none" };
  }
}

function main() {
  // The 5 s Stop timeout less node start-up and output; a test may move the origin back.
  const deadline = Date.now() - (Number(process.env.STOP_CONFIRM_CONTINUE_T0_OFFSET_MS) || 0) + STOP_BUDGET_MS;
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("stop-confirm-plan-guard", r, "confirm-plan check skipped") + "\n");
    } catch (_) {}
    process.exit(0);
  }
  const input = r.input;
  const active = input.stop_hook_active === true;

  const { resolveSessionId } = require("./workflow-state");
  const sid = resolveSessionId({ sessionIdFromInput: input.session_id, transcriptPath: input.transcript_path });
  if (!sid) process.exit(0);

  const TM = require("./lib/turn-marker");
  let markers = [];
  try { markers = TM.peekTurnMarkers(sid); } catch (_) { /* judged as a turn that wrote no plan */ }
  const { kind, tail } = readTail(input);
  if (kind !== "ok") {
    let unrecorded;
    try {
      unrecorded = kind === "undecidable" ? recordUndecidable({ sid, input, tail, markers, deadline }) : mayHavePresented(sid, markers, input);
    } catch (_) {
      unrecorded = mayHavePresented(sid, markers, input);
    }
    settleUnjudged(sid, active, unrecorded, TM);
  }

  let verdict;
  try {
    verdict = judgeTurn(Object.assign({ sid, markers, tail }, probesFor(deadline)));
  } catch (_) {
    // An exception says only that the turn could not be judged: earlier receipts stay.
    settleUnjudged(sid, active, mayHavePresented(sid, markers, input), TM);
  }

  if (active) {
    recordUnblocked(sid, verdict.block);
    process.exit(0);
  }
  TM.readAndDeleteTurnMarkers(sid);
  if (verdict.block) emitBlock(verdict.block.reason);
  const CC = require("./lib/confirm-continuation");
  const stage = CC.continuationStage(verdict.written, currentStage(sid));
  if (stage) emitBlock(CC.continueReason(stage));
  process.exit(0);
}

if (require.main === module) main();
