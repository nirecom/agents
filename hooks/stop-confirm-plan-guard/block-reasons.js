"use strict";
// hooks/stop-confirm-plan-guard/block-reasons.js — the Stop guard's block reasons, ranked by
// firstBlock: layer 2, plan-link, close-on-link, unpublished, plan-lang.

const fs = require("fs");
const path = require("path");
const SP = require("../lib/sentinel-patterns");

const PLAN_STAGES = ["intent", "outline", "detail"];

// The table's next skill for a plan suffix; detail may also branch straight to BRANCHING_COMPLETE.
function nextSkillFor(stage) {
  const { rowFor, stepForSuffix } = require("../workflow-state/plan-stage-table");
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
  const { relintPlanArtifact, formatPlanLangViolations } = require("../lib/plan-artifact-lang");
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
// stage: every file a marker names is checked, else <plans>/<first_session_id>-<stage>.md.
function filesOf(sid, markers, plansDir, stage) {
  const named = [];
  for (const m of markers) {
    if (m && m.suffix === stage && typeof m.absPath === "string" && m.absPath) named.push(m.absPath);
  }
  if (named.length > 0) return named;
  try {
    return [require("../workflow-state/plan-artifact-owner").resolvePlanArtifactOwner(sid, stage, undefined, { plansDir }).path];
  } catch (_) {
    return [];
  }
}

function planLinkReason(ctx) {
  const { sid, markers, tail, plansDir, gateFor, linkFor } = ctx;
  const tc = require("../lib/plan-link-turn-check");
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
  const tc = require("../lib/plan-link-turn-check");
  const CC = require("../lib/confirm-continuation");
  const { checkPlanApproval } = require("../workflow-state/plan-approval-check");
  const { stepForSuffix } = require("../workflow-state/plan-stage-table");
  const { approvalArtifactPath } = require("../lib/presentation-receipt");
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
  return { kind: "unpublished", reason: require("../lib/confirm-continuation").presentAgainReason(hit.stage, "unpublished") };
}

// Wrapped here, not in the reason builders: planLangReason is reused inside layer2Reason.
function convLang(reason) {
  try { return require("../lib/conv-lang").withConvLang(reason); } catch (_) { return reason; /* the bare reason still blocks */ }
}

// firstBlock(ctx, presented) -> {kind, reason} | null, in the order the reasons are ranked.
function firstBlock(ctx, presented) {
  const { sid, tail } = ctx;
  const content = tail.lastAssistantEntry && tail.lastAssistantEntry.message && tail.lastAssistantEntry.message.content;
  const l2 = Array.isArray(content) ? layer2Reason(sid, content, tail.entries) : null;
  if (l2) return { kind: "layer2", reason: convLang(l2) };
  const link = planLinkReason(ctx);
  if (link) return { kind: "plan-link", reason: convLang(link) };
  const found = closeOnLinkReason(ctx) || unpublishedReason(presented);
  if (found) return found;
  for (const p of presented) {
    const lang = planLangReason(sid, p.stage);
    if (lang) return { kind: "plan-lang", reason: convLang(lang) };
  }
  return null;
}

module.exports = { firstBlock, planLangReason, PLAN_STAGES };
