"use strict";

// Phase: adopt-prior-state (#1305). It runs first because a crash-restarted session
// (new id, no ancestry) starts empty while its work sits in a prior state file for the
// same cwd+branch, and /workflow-init is the first thing it runs. A ROUTE only: the
// decision is applied by hooks/workflow-state/inheritance/adopt.js, as for the
// bin/workflow/adopt-session-state CLI (CPR-SSOT). Default is `fresh`; adoption is
// opt-IN, so a non-interactive run takes the default and prints the recovery command.

const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..", "..");

const ASK_ID = "adopt_prior_state";

function loadAdopt() {
  return require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "inheritance", "adopt.js"));
}

function isNonInteractive() {
  const truthy = (v) => typeof v === "string" && v !== "" && v !== "0" && v.toLowerCase() !== "false";
  return truthy(process.env.CLAUDE_NON_INTERACTIVE) || truthy(process.env.CI);
}

/**
 * adoptPriorState(state, sessionId) → undefined | { ask, askId, question, options }
 */
function adoptPriorState(state, sessionId) {
  if (!sessionId) return;
  // Already decided in an earlier pass of this pipeline (post-answer re-entry).
  if (state.adopt_decision === "fresh") return;

  let adopt;
  try {
    adopt = loadAdopt();
  } catch (e) {
    return; // fail-open: optional recovery must never break /workflow-init
  }

  if (state.adopt_decision === "adopt") {
    const upstreamSid = state.adopt_candidate;
    if (!upstreamSid) return;
    const r = adopt.adoptState({ downstreamSid: sessionId, upstreamSid });
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
