"use strict";
// hooks/lib/presentation-turn.js — the one judgment of a plan presentation turn (#2936), shared by
// the Stop guard (hooks/stop-confirm-plan-guard.js) and any later caller that must reach the same
// verdict on the same tail. It takes no stop_hook_active / active / input: what only Stop does
// (carryMark, the unblocked notice, spending the markers) stays with the Stop guard.

const path = require("path");
const { firstBlock } = require("./presentation-turn/block-reasons");

const PROBE_RESERVE_MS = 500;

// probesFor(deadline, {seedGates}) -> {plansDir, gateFor, linkFor}: one gate probe per step within
// the budget (a spent budget reads ERROR, treated as ON) and one git lookup per plan file, shared
// by every check. gateFor takes the workflow step; seedGates ({step: gate}) are gates already known,
// not probed again.
function probesFor(deadline, { seedGates } = {}) {
  const { getWorkflowPlansDir } = require("./workflow-plans-dir");
  const { planGateState } = require("./confirm-gate/plan-gate");
  const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../../bin/workflow/lib/next-step/gate-line");
  const gates = Object.assign({}, seedGates && typeof seedGates === "object" ? seedGates : {});
  const gateFor = (step) => {
    if (!(step in gates)) {
      const timeoutMs = Math.min(NEXT_STEP_GATE_PROBE_TIMEOUT_MS, deadline - Date.now() - PROBE_RESERVE_MS);
      gates[step] = planGateState(step, { timeoutMs });
    }
    return gates[step];
  };
  const plansDir = getWorkflowPlansDir();
  const links = new Map();
  const linkFor = (absPath) => {
    const key = path.resolve(absPath);
    if (!links.has(key)) links.set(key, require("./plan-link").linkForFile(absPath, { plansDir }));
    return links.get(key);
  };
  return { plansDir, gateFor, linkFor };
}

// judgePresentationTurn({sid, tail, markers, plansDir, gateFor, linkFor}) -> {block, presented,
// anchorUuid}: the plans the tail presents, the first block reason (or null) and the uuid of the
// entry holding the last text block ("" when none).
function judgePresentationTurn({ sid, tail, markers, plansDir, gateFor, linkFor }) {
  const CC = require("./confirm-continuation");
  const ctx = { sid, tail, markers: Array.isArray(markers) ? markers : [], plansDir, gateFor, linkFor };
  const presented = CC.presentedArtifacts({ sid, tail, plansDir, gateFor, linkFor });
  const block = firstBlock(ctx, presented);
  const anchorUuid = tail.lastTextEntry ? tail.lastTextEntry.uuid : "";
  return { block, presented, anchorUuid };
}

module.exports = { PROBE_RESERVE_MS, probesFor, judgePresentationTurn };
