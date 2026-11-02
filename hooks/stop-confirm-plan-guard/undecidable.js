"use strict";
// hooks/stop-confirm-plan-guard/undecidable.js — the Stop guard's view of a turn whose tail it
// cannot confirm as final (#2771): where a presentation may be anchored, which plan artifacts the
// turn may have presented, and the notice for the plans whose receipt went unrecorded.

const fs = require("fs");
const path = require("path");
const { approvalArtifactPath } = require("../lib/presentation-receipt");
const { PLAN_ARTIFACT_NAMES } = require("../workflow-state/plan-step-table");

const THINKING = new Set(["thinking", "redacted_thinking"]);

// anchoredTailOf(tail) -> a copy of tail anchored on its last text entry, or null. It holds only
// when that entry has no tool_use and every assistant entry after it is thinking only.
function anchoredTailOf(tail) {
  const t = tail || {};
  const anchor = t.lastTextEntry;
  if (!anchor || typeof anchor.uuid !== "string" || !anchor.uuid) return null;
  const c = anchor.message && anchor.message.content;
  if (!Array.isArray(c) || c.some((it) => it && it.type === "tool_use")) return null;
  const entries = Array.isArray(t.entries) ? t.entries : [];
  // readTail re-parses the lines, so the anchor is found by uuid, not by identity.
  let at = -1;
  for (let i = entries.length - 1; i >= 0; i--) {
    if (entries[i] && entries[i].uuid === anchor.uuid) { at = i; break; }
  }
  if (at === -1) return null;
  for (const e of entries.slice(at + 1)) {
    if (!e || e.type !== "assistant") continue;
    const ec = e.message && e.message.content;
    if (!Array.isArray(ec) || !ec.every((it) => it && THINKING.has(it.type))) return null;
  }
  return Object.assign({}, t, { lastAssistantEntry: anchor });
}

// markerArtifacts(markers) -> the plan artifact names this turn wrote, each once.
function markerArtifacts(markers) {
  const out = [];
  for (const m of Array.isArray(markers) ? markers : []) {
    if (m && PLAN_ARTIFACT_NAMES.includes(m.suffix) && !out.includes(m.suffix)) out.push(m.suffix);
  }
  return out;
}

// mayHavePresented({sid, markers, input}) -> the plan artifact names the turn may have presented:
// those it wrote, and those whose existing <first_session_id>-<artifact>.md the last assistant
// message names. No git or gate probe.
function mayHavePresented({ sid, markers, input } = {}) {
  const out = markerArtifacts(markers);
  const text = input && typeof input.last_assistant_message === "string" ? input.last_assistant_message : "";
  for (const artifact of PLAN_ARTIFACT_NAMES) {
    if (out.includes(artifact) || !text) continue;
    const absPath = approvalArtifactPath(sid, artifact);
    if (absPath && text.includes(path.basename(absPath)) && fs.existsSync(absPath)) out.push(artifact);
  }
  return out;
}

// noticeFor(artifacts) -> the user-facing notice, or "" when no plan is left unrecorded. No URL: the
// plan repository is private.
function noticeFor(stages) {
  if (!Array.isArray(stages) || stages.length === 0) return "";
  return `[confirm-plan] The presentation of the ${stages.join(", ")} plan could not be confirmed this turn, ` +
    "so it may need to be presented again before approval.";
}

module.exports = { anchoredTailOf, markerArtifacts, mayHavePresented, noticeFor };
