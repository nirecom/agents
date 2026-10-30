"use strict";
// Every workflow-gate block, recorded once — from inside block() itself rather
// than at its twelve call sites, so "a blocked gate is never forgotten" holds
// by construction instead of by twelve edits that would drift apart.

const { appendStateHandoffRecord } = require("../lib/state-handoff-record");
const { recordRiskSignal } = require("../lib/risk-signal");
const { isValidAtStep, NO_STEP } = require("../workflow-state/state-io/state-handoff-record-schema");

const GATE_BLOCK_KEY = "gate:block";
const MAX_SUMMARY = 300;

function currentStepFor(sid) {
  try {
    const { resolveCurrentEffectiveStep } = require("../workflow-state/current-step");
    const step = resolveCurrentEffectiveStep(sid);
    return isValidAtStep(step) ? step : NO_STEP;
  } catch (e) {
    return NO_STEP;
  }
}

function summarize(reason) {
  const text = String(reason === undefined || reason === null ? "" : reason).trim();
  if (text.length <= MAX_SUMMARY) return text;
  return text.slice(0, MAX_SUMMARY);
}

// The key is FIXED, never a hash of the reason: the resume view must show the
// block that is still true, and a reason-derived key would show every block
// this session ever hit as if all of them still stood.
function recordGateBlock(sid, reason, ctx) {
  try {
    recordRiskSignal(sid, "gate-block");
  } catch (_e) { /* a lost stamp must not cost the entry */ }
  try {
    const pointer = ctx && typeof ctx.command === "string" && ctx.command.length ? ctx.command : "-";
    const res = appendStateHandoffRecord(sid, {
      cls: "C",
      step: currentStepFor(sid),
      key: GATE_BLOCK_KEY,
      summary: summarize(`${GATE_BLOCK_KEY} — ${reason}`),
      pointer: summarize(pointer),
      origin: "gate-block",
    });
    // recordGateBlock keeps its pre-#2652 contract: a written entry answers reason "ok".
    return res && res.written ? { written: true, reason: "ok" } : res;
  } catch (e) {
    return { written: false, reason: "io-error" };
  }
}

module.exports = { GATE_BLOCK_KEY, recordGateBlock };
