"use strict";
// Replay of the recorded reset events (#2852). The allowance starts at 2 and each reset event
// spends or refills it under the same rule the gate applies now (applyRule). A past reset that
// went through an ask was recorded only after the user approved it, so it reads back as approved.

const { VALID_STEPS } = require("../state-io");
const { projectState } = require("../state-io/projection");
const { phaseOf, canonicalStepName } = require("../step-table");
const { PLAN_STEP_TABLE } = require("../plan-step-table");
const { isConfirmFlagOffFromFile } = require("../../lib/plan-confirm-flag");
const { isForwardAt, settledAt } = require("./forward");

const ALLOWANCE = 2;
const BRANCHING = "branching_complete";
const PRE = "pre-implementation";

// flagReader() -> (target) => true when a CONFIRM_* flag of the target's plan row or a later one
// is not off. Each flag is read from the .env file once per decision.
function flagReader() {
  const memo = new Map();
  const isOff = (flag) => {
    if (!memo.has(flag)) memo.set(flag, isConfirmFlagOffFromFile(flag));
    return memo.get(flag);
  };
  return (target) => {
    const at = VALID_STEPS.indexOf(target);
    return Object.keys(PLAN_STEP_TABLE).some((step) => VALID_STEPS.indexOf(step) >= at && !isOff(PLAN_STEP_TABLE[step].confirmFlag));
  };
}

// applyRule(target, allowance, flagHit) -> { outcome: "passed" | "approved", allowance }.
function applyRule(target, allowance, flagHit) {
  const phase = phaseOf(target);
  if (phase === null) return { outcome: "approved", allowance };
  if (phase === PRE) {
    if (flagHit(target) || allowance <= 0) return { outcome: "approved", allowance: ALLOWANCE };
    return { outcome: "passed", allowance: allowance - 1 };
  }
  if (allowance > 0) return { outcome: "passed", allowance: allowance - 1 };
  return { outcome: "approved", allowance };
}

function prefixState(state, prefix) {
  return Object.assign({}, state, { events: prefix }, projectState(Object.assign({}, state, { events: prefix })));
}

// A reset is judged forward only while the profile it was read under still holds: no later
// reset to branching_complete or earlier (that un-pins the profile) and branching_complete settled.
function wasForward(state, events, i, target, profile, laterUnpin) {
  if (laterUnpin) return false;
  const prefix = prefixState(state, events.slice(0, i));
  if (!settledAt(prefix, BRANCHING, profile)) return false;
  return isForwardAt(prefix, target, profile);
}

// replayResets(state, profile, flagHit) -> { allowance, rows: [{ seq, at, from_step, reason, outcome }] }.
function replayResets(state, profile, flagHit) {
  const events = state.events;
  const resetIdx = [];
  events.forEach((e, i) => { if (e && e.kind === "reset") resetIdx.push(i); });
  const branchingIdx = VALID_STEPS.indexOf(BRANCHING);
  let allowance = ALLOWANCE;
  const rows = [];
  resetIdx.forEach((i, k) => {
    const e = events[i];
    const target = canonicalStepName(e.from_step);
    const laterUnpin = resetIdx.slice(k + 1).some((j) => {
      const t = VALID_STEPS.indexOf(canonicalStepName(events[j].from_step));
      return t !== -1 && t <= branchingIdx;
    });
    let r;
    if (wasForward(state, events, i, target, profile, laterUnpin)) {
      r = { outcome: "approved", allowance: phaseOf(target) === PRE ? ALLOWANCE : allowance };
    } else {
      r = applyRule(target, allowance, flagHit);
    }
    allowance = r.allowance;
    rows.push({ seq: e.seq, at: typeof e.at === "string" ? e.at : "", from_step: target, reason: String(e.reason || ""), outcome: r.outcome });
  });
  return { allowance, rows };
}

module.exports = { ALLOWANCE, flagReader, applyRule, replayResets };
