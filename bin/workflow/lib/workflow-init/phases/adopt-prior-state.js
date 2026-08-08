"use strict";

/**
 * Phase: adopt-prior-state (#1305)
 *
 * WHY it runs first: since inheritance became lineage-keyed, a session that
 * crash-restarted (new id, no ancestry) starts empty even though its work is
 * sitting in a prior state file for the same cwd+branch. /workflow-init is the
 * first thing such a session runs, so it is where the offer belongs — before any
 * issue detection has written anything.
 *
 * This phase is a ROUTE, never a second implementation: the decision is applied
 * by hooks/workflow-state/inheritance/adopt.js, the same function the
 * bin/workflow/adopt-session-state CLI calls (CPR-SSOT).
 *
 * Default is always `fresh`. Adoption is opt-IN, so a non-interactive run
 * (CLAUDE_NON_INTERACTIVE / CI) must not hard-fail — it takes the default and
 * prints the exact recovery command instead.
 */

const path = require("path");

const ASK_ID = "adopt_prior_state";

function loadAdopt(agentsConfigDir) {
  const dir = agentsConfigDir || path.resolve(__dirname, "../../../../..");
  return require(path.join(dir, "hooks", "workflow-state", "inheritance", "adopt.js"));
}

function isNonInteractive() {
  const truthy = (v) => typeof v === "string" && v !== "" && v !== "0" && v.toLowerCase() !== "false";
  return truthy(process.env.CLAUDE_NON_INTERACTIVE) || truthy(process.env.CI);
}

/**
 * adoptPriorState(state, agentsConfigDir, sessionId) → undefined | { ask, askId, question, options }
 */
function adoptPriorState(state, agentsConfigDir, sessionId) {
  if (!sessionId) return;
  // Already decided in an earlier pass of this pipeline (post-answer re-entry).
  if (state.adopt_decision === "fresh") return;

  let adopt;
  try {
    adopt = loadAdopt(agentsConfigDir);
  } catch (e) {
    return; // fail-open: optional recovery must never break /workflow-init
  }

  if (state.adopt_decision === "adopt") {
    const donor = state.adopt_candidate;
    if (!donor) return;
    const r = adopt.adoptState({ heirSid: sessionId, donorSid: donor });
    if (!r.ok) {
      process.stderr.write(`[workflow-init] NOTICE: adoption refused — ${r.error}\n`);
    }
    // Either way the decision is spent; do not re-offer on a later pass.
    state.adopt_candidate = null;
    state.adopt_decision = "fresh";
    return;
  }

  let listing;
  try {
    listing = adopt.listAdoptCandidates(sessionId);
  } catch (e) {
    return;
  }
  if (!listing || !listing.ok || listing.candidates.length === 0) return;

  const top = listing.candidates[0];
  state.adopt_candidate = top.sessionId;

  if (isNonInteractive()) {
    // "Not adopted" must never mean "not told" (CPR-E2E). stderr, not stdout:
    // stdout carries the KEY=VALUE directive contract this driver speaks.
    process.stderr.write(
      `[workflow-init] NOTICE: a prior session on this cwd+branch has workflow state ` +
      `(${top.sessionId}, last activity ${top.last_activity || "unknown"}). It was NOT adopted.\n` +
      `[workflow-init] NOTICE: to adopt it, run from the agents repo root:\n` +
      `  node bin/workflow/adopt-session-state --session ${sessionId} --from ${top.sessionId}\n`
    );
    state.adopt_decision = "fresh";
    state.adopt_candidate = null;
    return;
  }

  return {
    ask: true,
    askId: ASK_ID,
    question:
      `A prior session ${top.sessionId} on this cwd+branch has workflow state ` +
      `(last activity ${top.last_activity || "unknown"}). ` +
      `Is this session a continuation of it?`,
    options: "fresh (start clean — default) | adopt (carry that session's completed steps over)",
  };
}

module.exports = { adoptPriorState, ADOPT_PRIOR_STATE_ASK_ID: ASK_ID };
