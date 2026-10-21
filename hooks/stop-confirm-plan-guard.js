#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan protocol. Each check returns a block reason or
// null; the first reason found blocks (layer 2, plan-link, close-on-link, unpublished, plan-lang).
// Layer 2 (#2278): a CONFIRM echo in the last assistant entry needs a PLAN_LANG-clean plan and a
// stage-valid follow-up tool_use. Plan-link: a turn that wrote a plan shows its link line — in the
// last text block when the stage's gate is ON, anywhere in the turn when it is OFF.
// Presentation (#2729): a turn the hook lets through that closes on unapproved stages' link lines
// gets a presentation receipt per stage (hooks/lib/presentation-receipt.js); a blocked turn voids
// every receipt of the session, and the current stage is continued once for the CONFIRM echo.
// Reason prefixes and the marker contract: docs/architecture/claude-code/settings.md.
"use strict";

const fs = require("fs");
const path = require("path");
const SP = require("./lib/sentinel-patterns");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

const STOP_BUDGET_MS = 4000;
const PROBE_RESERVE_MS = 500;
const PLAN_STAGES = ["intent", "outline", "detail"];

// The table's next skill for a plan suffix; detail may also branch straight to BRANCHING_COMPLETE.
function nextSkillFor(stage) {
  const { rowFor, stepForSuffix } = require("./workflow-state/plan-stage-table");
  const row = rowFor(stepForSuffix(stage));
  return row ? row.nextSkill : null;
}

// Whether the tool_result answering tool_use `id` reports an error (a denied echo).
function resultIsError(entries, id) {
  if (typeof id !== "string" || !id) return false;
  for (const e of entries) {
    const c = e && e.type === "user" && e.message && e.message.content;
    if (!Array.isArray(c)) continue;
    for (const it of c) {
      if (it && it.type === "tool_result" && it.tool_use_id === id) return it.is_error === true;
    }
  }
  return false;
}

// The stage's plan violates PLAN_LANG (#2278): Layer 2 and the presentation share it.
function planLangReason(sid, stage) {
  const { relintPlanArtifact, formatPlanLangViolations } = require("./lib/plan-artifact-lang");
  const relint = relintPlanArtifact(sid, stage);
  if (relint.skipped !== null || relint.violations.length === 0) return null;
  return "[confirm-plan] Layer 2/plan-lang: " + path.basename(relint.artifactPath) +
    " violates plan-artifact language/heading rules (PLAN_LANG=" + relint.policy + ", " +
    relint.violations.length + " line(s)) — fix body language and use canonical English schema headings before CONFIRM_" +
    stage.toUpperCase() + ":\n" + formatPlanLangViolations(relint.violations).join("\n");
}

function layer2Reason(sid, content, entries) {
  let confirmIdx = -1;
  let stage = null;
  for (let i = 0; i < content.length; i++) {
    const item = content[i];
    if (!item || item.type !== "tool_use" || item.name !== "Bash") continue;
    const c = item.input && item.input.command;
    if (typeof c !== "string") continue;
    stage = SP.CONFIRM_INTENT_RE_DQ.test(c) ? "intent" : SP.CONFIRM_OUTLINE_RE_DQ.test(c) ? "outline"
      : SP.CONFIRM_DETAIL_RE_DQ.test(c) ? "detail" : null;
    if (stage) { confirmIdx = i; break; }
  }
  if (confirmIdx === -1) return null;
  if (resultIsError(entries, content[confirmIdx].id)) return null;
  // Re-lint the confirmed artifact before the follow-up check: a non-compliant plan must be
  // rewritten, not merely continued (#2278).
  const lang = planLangReason(sid, stage);
  if (lang) return lang;
  const nextSkill = nextSkillFor(stage);
  for (let i = confirmIdx + 1; i < content.length; i++) {
    const item = content[i];
    if (!item || item.type !== "tool_use") continue;
    if (item.name === "Skill" && item.input && typeof item.input.skill === "string" &&
        nextSkill && item.input.skill.includes(nextSkill)) return null;
    if (stage === "detail" && item.name === "Bash" && item.input && typeof item.input.command === "string"
        && item.input.command.includes("WORKFLOW_BRANCHING_COMPLETE")) return null;
  }
  // #871: a found follow-up may later markStep(sid, stage, "complete") here.
  const hint = nextSkill ? nextSkill + (stage === "detail" ? " or WORKFLOW_BRANCHING_COMPLETE" : "") : "";
  return "[confirm-plan] Layer 2/follow-up: stage-valid follow-up Skill not found after CONFIRM_" +
    stage.toUpperCase() + (hint ? " — invoke " + hint : "");
}

// A written artifact may carry another session's id, and one call may write several files of a
// stage: every file a marker names is checked, else <plans>/<sid>-<stage>.md.
function filesOf(sid, markers, plansDir, stage) {
  const named = [];
  for (const m of markers) {
    if (m && m.suffix === stage && typeof m.absPath === "string" && m.absPath) named.push(m.absPath);
  }
  return named.length > 0 ? named : [path.join(plansDir, `${sid}-${stage}.md`)];
}

function planLinkReason(ctx) {
  const { sid, markers, tail, plansDir, gateFor, linkFor } = ctx;
  const tc = require("./lib/plan-link-turn-check");
  // Stop judges only the stages this turn wrote; a CONFIRM turn is judged at PreToolUse.
  const stages = tc.stagesToCheck({ markers, includeConfirm: false });
  for (const stage of stages) {
    // OFF needs the line once in the turn; ON and ERROR need it in the last text block.
    const scope = gateFor(stage) === "OFF" ? "turn" : "last";
    for (const absPath of filesOf(sid, markers, plansDir, stage)) {
      const verdict = tc.checkPlanUrlInTurn({
        stages: [stage], turnText: tail.lastTextBlock || "", entries: tail.entries, scope,
        resolve: () => linkFor(absPath),
      });
      if (verdict.block) return verdict.reason;
    }
  }
  return null;
}

// Gap 5: an unapproved stage's link line in the last text block must close it. Every stage whose
// link appears there is judged, so a re-quoted earlier plan followed by prose blocks too.
function closeOnLinkReason(ctx) {
  const { sid, markers, tail, plansDir, gateFor, linkFor } = ctx;
  const tc = require("./lib/plan-link-turn-check");
  const CC = require("./lib/confirm-continuation");
  const { checkPlanApproval } = require("./workflow-state/plan-approval-check");
  const { stepForSuffix } = require("./workflow-state/plan-stage-table");
  const { approvalArtifactPath } = require("./lib/presentation-receipt");
  const lastText = tail.lastTextBlock || "";
  for (const stage of PLAN_STAGES) {
    const approved = approvalArtifactPath(sid, stage);
    const files = markers.some((m) => m && m.suffix === stage) || !approved
      ? filesOf(sid, markers, plansDir, stage) : [approved];
    for (const absPath of files) {
      if (!fs.existsSync(absPath)) continue;
      const link = linkFor(absPath);
      if (tc.shown(link, lastText) !== true) continue;
      if (tc.inTrailingLinkRun(lastText, Object.assign({ stage }, link))) continue;
      const gate = gateFor(stage);
      if (gate === "OFF") continue;
      if (checkPlanApproval(sid, stepForSuffix(stage), { gate }).verdict !== "unapproved") continue;
      return { kind: "not-last", reason: CC.presentAgainReason(stage, "not-last") };
    }
  }
  return null;
}

function unpublishedReason(presented) {
  const hit = presented.find((p) => !p.receiptLink);
  if (!hit) return null;
  return { kind: "unpublished", reason: require("./lib/confirm-continuation").presentAgainReason(hit.stage, "unpublished") };
}

// firstBlock(ctx, presented) -> {kind, reason} | null, in the order the reasons are ranked.
function firstBlock(ctx, presented) {
  const { sid, tail } = ctx;
  const content = tail.lastAssistantEntry && tail.lastAssistantEntry.message && tail.lastAssistantEntry.message.content;
  const l2 = Array.isArray(content) ? layer2Reason(sid, content, tail.entries) : null;
  if (l2) return { kind: "layer2", reason: l2 };
  const link = planLinkReason(ctx);
  if (link) return { kind: "plan-link", reason: link };
  const found = closeOnLinkReason(ctx) || unpublishedReason(presented);
  if (found) return found;
  for (const p of presented) {
    const lang = planLangReason(sid, p.stage);
    if (lang) return { kind: "plan-lang", reason: lang };
  }
  return null;
}

// judgeTurn(ctx) -> {block, written}: voids every receipt on a block, else writes one per
// presented stage that has a receipt link. Throws are the caller's (it voids the receipts).
function judgeTurn(ctx) {
  const CC = require("./lib/confirm-continuation");
  const PR = require("./lib/presentation-receipt");
  const presented = CC.presentedStages({ sid: ctx.sid, tail: ctx.tail, plansDir: ctx.plansDir, gateFor: ctx.gateFor, linkFor: ctx.linkFor });
  const block = firstBlock(ctx, presented);
  if (block) {
    PR.discardAllReceipts(ctx.sid);
    return { block, written: [] };
  }
  const written = [];
  for (const p of presented) {
    const ok = p.receiptLink && PR.writeReceipt(ctx.sid, p.stage, {
      absPath: p.absPath, link: p.receiptLink, contentSha: p.contentSha, anchorUuid: ctx.tail.lastTextEntry.uuid,
    });
    if (ok) written.push(p); else PR.discardReceipt(ctx.sid, p.stage);
  }
  return { block: null, written };
}

// Under stop_hook_active nothing is blocked, so a Gap 5 or unpublished hit is left for the supervisor.
function recordUnblocked(sid, block) {
  if (!block || (block.kind !== "not-last" && block.kind !== "unpublished")) return;
  try {
    require("./lib/supervisor-state-writer").appendFinding(sid, {
      categories: ["workflow"],
      severity: "notice",
      detail: `stop-confirm-plan-guard: ${block.kind} presentation passed unblocked (stop_hook_active); every receipt voided`,
      reporter: "stop-confirm-plan-guard",
    });
  } catch (_) { /* the finding is advisory */ }
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

function readTail(input) {
  try {
    const { readTurnTail, parseLines } = require("./lib/transcript-reader");
    const tail = readTurnTail({ input });
    if (tail.undecidable) return null;
    tail.entries = parseLines(tail.lines);
    const content = tail.lastAssistantEntry && tail.lastAssistantEntry.message && tail.lastAssistantEntry.message.content;
    return tail.lastAssistantEntry && !Array.isArray(content) ? null : tail;
  } catch (_) {
    return null;
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
  const tail = readTail(input);
  if (!tail) {
    // An undecidable turn is let through; its markers are spent so they cannot judge the next turn.
    if (!active) TM.readAndDeleteTurnMarkers(sid);
    process.exit(0);
  }

  let verdict;
  try {
    const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
    const { planGateState } = require("./lib/confirm-gate/plan-gate");
    const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../bin/workflow/lib/next-step/gate-line");
    const gates = {};
    // One probe per stage, within the budget; a spent budget reads ERROR, treated as ON.
    const gateFor = (stage) => {
      if (!(stage in gates)) {
        const timeoutMs = Math.min(NEXT_STEP_GATE_PROBE_TIMEOUT_MS, deadline - Date.now() - PROBE_RESERVE_MS);
        gates[stage] = planGateState(stage, { timeoutMs });
      }
      return gates[stage];
    };
    const plansDir = getWorkflowPlansDir();
    // One git lookup per plan file: the plan-link, close-on-link and presentation checks share it.
    const links = new Map();
    const linkFor = (absPath) => {
      const key = path.resolve(absPath);
      if (!links.has(key)) links.set(key, require("./lib/plan-link").linkForFile(absPath, { plansDir }));
      return links.get(key);
    };
    verdict = judgeTurn({ sid, markers: TM.peekTurnMarkers(sid), tail, plansDir, gateFor, linkFor });
  } catch (_) {
    try { require("./lib/presentation-receipt").discardAllReceipts(sid); } catch (_e) { /* nothing more to void */ }
    process.exit(0);
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
