"use strict";
// hooks/lib/confirm-continuation.js — the same-turn CONFIRM continuation (#2650), shared by the
// Stop hook (stop-confirm-plan-guard.js) and the PreToolUse hook (confirm-checkpoint.js).
// The Stop hook picks the one plan stage to continue and writes a mark bound to the approval
// target (path, link shown, sha); confirm-checkpoint accepts the echo of the same turn only when
// the mark's anchor closes that turn and the mark still binds today's file.

const fs = require("fs");
const path = require("path");
const { resolvePlanArtifactOwner } = require("../workflow-state/plan-artifact-owner");
const { normalizeSlashes } = require("./path-match");
const { parseSentinel } = require("./confirm-sentinel");
const { isCommandTool, commandTextOf } = require("./tool-command-text");
const { linkForFile, STAGES, PLAN_LINK_COMMAND } = require("./plan-link");
const { endsWithLinkLine, stagesToCheck, turnEntriesOf } = require("./plan-link-turn-check");
const { planGateState } = require("./confirm-gate/plan-gate");
const { stepForSuffix } = require("../workflow-state/plan-stage-table");
const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../../bin/workflow/lib/next-step/gate-line");

// Below this, a probe cannot finish within the Stop hook's budget; the turn ends as before.
const MIN_PROBE_MS = 200;

// The approval target is the owner-resolved file (plan-artifact-owner.js), the one the approval
// handler hashes: a resumed session's target is its upstream's file (#2631).
function approvalArtifactOwner(sid, stage) {
  try { return resolvePlanArtifactOwner(sid, stage); } catch (_) { return null; }
}

function approvalArtifactPath(sid, stage) {
  const owner = approvalArtifactOwner(sid, stage);
  return owner ? owner.path : null;
}

function approvalArtifactSha(sid, stage) {
  const owner = approvalArtifactOwner(sid, stage);
  if (!owner) return null;
  const { computeArtifactSha } = require("../workflow-state/completion-approval");
  return computeArtifactSha(owner.ownerSid, stepForSuffix(stage));
}

function linkKey(link) {
  if (!link || typeof link !== "object") return null;
  if (typeof link.url === "string" && link.url) return link.url;
  if (typeof link.path === "string" && link.path) return link.path;
  return null;
}

function samePath(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || !a || !b) return false;
  const norm = (p) => {
    const r = normalizeSlashes(path.resolve(p));
    return process.platform === "win32" ? r.toLowerCase() : r;
  };
  try { return norm(a) === norm(b); } catch (_) { return false; }
}

function itemsOf(entry, type) {
  if (!entry || entry.type !== "assistant") return [];
  const c = entry.message && entry.message.content;
  return Array.isArray(c) ? c.filter((it) => it && it.type === type) : [];
}

function toolUsesOf(entry) {
  return itemsOf(entry, "tool_use");
}

function textsOf(entry) {
  return itemsOf(entry, "text").filter((it) => typeof it.text === "string").map((it) => it.text);
}

// An anchor that also ran a tool did not close the turn on the plan link alone.
function anchorHasToolUse(entry) {
  return toolUsesOf(entry).length > 0;
}

function isStageEcho(item, stage) {
  if (!isCommandTool(item.name)) return false;
  const hit = parseSentinel(commandTextOf(item.name, item.input));
  return !!hit && hit.stage === stage;
}

function anchorIndex(entries, mark) {
  if (!mark || typeof mark.anchorUuid !== "string" || !mark.anchorUuid) return -1;
  return entries.findIndex((e) => e && e.uuid === mark.anchorUuid);
}

// anchorClosesOnLink(entries, mark, stage, link) -> whether the anchor's last text item ends with
// the stage's plan-link line for link, followed only by whitespace.
function anchorClosesOnLink(currentTurnEntries, mark, stage, link) {
  const entries = Array.isArray(currentTurnEntries) ? currentTurnEntries : [];
  const at = anchorIndex(entries, mark);
  if (at === -1) return false;
  const texts = textsOf(entries[at]);
  return texts.length > 0 && endsWithLinkLine(stage, link, texts[texts.length - 1]);
}

// sameTurnContinuation(entries, mark, selfToolUseId) -> whether the mark's anchor sits in this
// turn and nothing but this echo (or, without an id, the stage's echo) followed it — no tool, no text.
function sameTurnContinuation(currentTurnEntries, mark, selfToolUseId) {
  const entries = Array.isArray(currentTurnEntries) ? currentTurnEntries : [];
  const at = anchorIndex(entries, mark);
  if (at === -1 || anchorHasToolUse(entries[at])) return false;
  for (const entry of entries.slice(at + 1)) {
    if (textsOf(entry).some((t) => t.trim() !== "")) return false;
    for (const item of toolUsesOf(entry)) {
      if (selfToolUseId ? item.id !== selfToolUseId : !isStageEcho(item, mark.stage)) return false;
    }
  }
  return true;
}

function markBindsArtifact(mark, target) {
  if (!mark || !target) return false;
  if (!samePath(mark.absPath, target.absPath)) return false;
  const key = linkKey(target.link);
  if (!key || mark.link !== key) return false;
  return typeof mark.artifactSha === "string" && !!mark.artifactSha && mark.artifactSha === target.sha;
}

function unapproved(sid, stage) {
  try {
    const { checkPlanApproval } = require("../workflow-state/plan-approval-check");
    return checkPlanApproval(sid, stepForSuffix(stage)).verdict === "unapproved";
  } catch (_) {
    return false;
  }
}

// One spawn-free check, the same for every stage (S3 steps 1-5).
function candidateOf(stage, { sid, lastText, plansDir, markers, echoed }) {
  const absPath = approvalArtifactPath(sid, stage);
  if (!absPath || !fs.existsSync(absPath)) return null;
  const others = (markers || []).filter((m) => m && m.suffix === stage && !samePath(m.absPath, absPath));
  if (others.length > 0) return null;
  let link = null;
  try { link = linkForFile(absPath, { plansDir }); } catch (_) { link = null; }
  if (!endsWithLinkLine(stage, link, lastText)) return null;
  if (echoed.includes(stage)) return null;
  if (!unapproved(sid, stage)) return null;
  return { stage, absPath, link };
}

// pickContinuationStage(opts) -> {stage, absPath, link, sha} | null. Probes at most once.
function pickContinuationStage({ sid, lastText, plansDir, markers, entries, probe, timeoutMsFor } = {}) {
  const echoed = stagesToCheck({ markers: [], turnEntries: turnEntriesOf(entries) });
  const found = STAGES.map((stage) => candidateOf(stage, { sid, lastText, plansDir, markers, echoed })).filter(Boolean);
  if (found.length !== 1) return null;
  const c = found[0];
  const timeoutMs = typeof timeoutMsFor === "function" ? timeoutMsFor() : NEXT_STEP_GATE_PROBE_TIMEOUT_MS;
  if (!(timeoutMs >= MIN_PROBE_MS)) return null;
  const gate = typeof probe === "function" ? probe : planGateState;
  if (gate(c.stage, { timeoutMs }) !== "ON") return null;
  const sha = approvalArtifactSha(sid, c.stage);
  if (!sha) return null;
  return { stage: c.stage, absPath: c.absPath, link: c.link, sha };
}

function continueReason(stage) {
  const S = String(stage).toUpperCase();
  return `[confirm-plan] continue: as your next message, emit only echo "<<WORKFLOW_CONFIRM_${S}: {one-line summary}>>" — the approval dialog follows.`;
}

function sameTurnDenyReason(stage) {
  const S = String(stage).toUpperCase();
  return `[confirm-checkpoint] CONFIRM_${S} denied: the ${stage} plan was not shown, as the message that closed the turn, right before this echo. ` +
    `Do not echo it again in this turn. Run ${PLAN_LINK_COMMAND.replace("<stage>", stage)}, end this turn with its output as-is, wait for the user's reply, ` +
    "then echo the CONFIRM alone in the next turn without rewriting the plan.";
}

module.exports = {
  MIN_PROBE_MS,
  approvalArtifactPath, approvalArtifactSha, linkKey, samePath, anchorHasToolUse, anchorClosesOnLink, sameTurnContinuation, markBindsArtifact,
  pickContinuationStage, continueReason, sameTurnDenyReason,
};
