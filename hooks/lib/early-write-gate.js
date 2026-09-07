"use strict";
// hooks/lib/early-write-gate.js — is the early write gate actually gating right now?
//
// SSOT for that question (CPR-SSOT): hooks/workflow-gate/early-gate.js decides whether
// to block, and hooks/bash-guard/judge.js decides whether to stay quiet, from this one
// computation. The order below is load-bearing: WORKFLOW_OFF is read FIRST, because
// hooks/workflow-gate.js approves on that marker before early-gate ever runs. A reader
// that only scanned step status would report active:true for a session whose gate never
// fires, silencing bash-guard for the whole session.

const { readState, reconcileEffectiveState } = require("../workflow-state");
const { isWorkflowOff } = require("./session-markers");

const EARLY_TIERS = Object.freeze(["workflow_init", "clarify_intent"]);
const SETTLED = new Set(["complete", "skipped"]);

/**
 * Tier status over an already-read state record, without the WORKFLOW_OFF question.
 * early-gate.js calls this directly: it is reached only when workflow-gate.js has
 * already cleared the marker, so re-reading it there would be a second, divergent order.
 * @param {object} state raw record from readState()
 * @param {string} sessionId
 * @returns {{active: boolean, pendingTier: string|null}}
 */
function earlyTierStatus(state, sessionId) {
  let snapshot = null;
  try {
    snapshot = reconcileEffectiveState(state, sessionId, {
      isWfMeta: state && state.workflow_type === "wf-meta",
      evidencePolicy: "staged-only",
    });
  } catch (_e) {
    snapshot = null;
  }
  // Fail-closed on snapshot failure: fall back to the raw record, never to "complete".
  const statusOf = (step) => {
    const src = snapshot && snapshot.steps ? snapshot.steps : (state && state.steps) || {};
    return (src[step] || {}).status || "pending";
  };
  for (const tier of EARLY_TIERS) {
    if (!SETTLED.has(statusOf(tier))) return { active: true, pendingTier: tier };
  }
  return { active: false, pendingTier: null };
}

/**
 * @param {string} sessionId
 * @returns {{active: boolean, pendingTier: string|null, state: object|null, inactiveReason: string|null}}
 */
function earlyWriteGateStatus(sessionId) {
  const inactive = (reason, state) => ({
    active: false,
    pendingTier: null,
    state: state || null,
    inactiveReason: reason,
  });

  try {
    if (!sessionId || typeof sessionId !== "string") return inactive("no-state");
    if (isWorkflowOff(sessionId)) return inactive("workflow-off");

    const state = readState(sessionId);
    if (!state) return inactive("no-state");

    const tier = earlyTierStatus(state, sessionId);
    if (!tier.active) return inactive("no-pending-tier", state);
    return { active: true, pendingTier: tier.pendingTier, state, inactiveReason: null };
  } catch (_e) {
    // The gate cannot be proven armed, so report it inactive and name why.
    return inactive("no-state");
  }
}

module.exports = { earlyWriteGateStatus, earlyTierStatus, EARLY_TIERS };
