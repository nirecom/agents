"use strict";
// decideReset (#2852): allow or ask for one RESET_FROM_<target>. Reads only; any doubt asks.
// The current step is next-step's own (reconciled-current-step), so a reset past the step the
// session stands on always asks; otherwise the replayed allowance and the CONFIRM_* flags decide.

const { VALID_STEPS } = require("../state-io");
const { assertStreamIntegrity } = require("../state-io/projection");
const { phaseOf, canonicalStepName } = require("../step-table");
const { resolveReconciledCurrentStep } = require("../reconciled-current-step");
const { flagReader, applyRule, replayResets } = require("./replay");

const EMPTY_REPLAY = Object.freeze({ allowance: null, rows: Object.freeze([]) });

function decideReset(args) {
  const { state, sid, target, repoDir } = args || {};
  const checkpoint = typeof (args && args.checkpoint) === "function" ? args.checkpoint : () => {};
  let replay = EMPTY_REPLAY;
  const ask = (why) => ({ decision: "ask", why, replay });
  try {
    if (!state || typeof state !== "object" || !Array.isArray(state.events)) return ask("state-unreadable");
    assertStreamIntegrity(state.events);
    if (!state.steps || typeof state.steps !== "object") return ask("state-unreadable");
    const profile = require("../session-profile").resolveSessionProfile(state, sid, { repoDir });
    checkpoint("current-step");
    const cur = resolveReconciledCurrentStep(state, sid, { repoDir, profile });
    if (!cur.ok) return ask("current-step-unreadable");
    if (cur.step === null) return ask("no-current-step");
    const step = canonicalStepName(target);
    if (phaseOf(step) === null) return ask("unknown-step");
    if (VALID_STEPS.indexOf(step) > VALID_STEPS.indexOf(cur.step)) return ask(`target-after-current-step (${cur.step})`);
    checkpoint("replay");
    const flagHit = flagReader();
    replay = replayResets(state, profile, flagHit);
    const r = applyRule(step, replay.allowance, flagHit);
    if (r.outcome === "passed") return { decision: "allow", why: "allowance", replay };
    return ask(phaseOf(step) === "pre-implementation" && flagHit(step) ? "confirm-flag-not-off" : "allowance-spent");
  } catch (e) {
    try { process.stderr.write(`decideReset: ${(e && e.stack) || e}\n`); } catch { /* the ask stands */ }
    return ask("error: decide-failed");
  }
}

module.exports = { decideReset };
