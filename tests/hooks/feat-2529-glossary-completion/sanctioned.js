"use strict";
// T6-2: the sanctioned tokens reset-sentinel and session-inherit are not judged by the glossary
// boundary, and a step already recorded complete is not reverted for a missing record.
// T6-3: the early-gate snapshot (evidencePolicy "staged-only") resolves an approved pending
// clarify_intent to complete only when its glossary_check record is valid.

const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");

function sanctioned() {
  for (const token of ["reset-sentinel", "session-inherit"]) {
    for (const stage of F.STAGES) {
      const step = F.STAGE_STEP[stage];
      const s = F.setupStage(`sanct-${stage}`, stage, F.VARIANT);
      const res = F.completeInProcess(s.sid, step, s.repo, { sanctioned: token, reason: "fixture sanctioned completion" });
      F.check(`${token} ${stage}: no glossary refusal without a record`, res.ok === true, JSON.stringify(res));
      F.check(`${token} ${stage}: ${step} is complete`, F.statusOf(s.sid, step) === "complete", F.statusOf(s.sid, step));
    }
  }
}

// A step recorded complete before the glossary predicate existed keeps reading complete.
function alreadyComplete() {
  const { reconcileEffectiveState, isUnapprovedGatedComplete } = require(path.join(F.ROOT, "hooks/workflow-state/effective-state.js"));
  for (const stage of F.STAGES) {
    const step = F.STAGE_STEP[stage];
    const s = F.setupStage(`done-${stage}`, stage, F.VARIANT, { ownStatus: "complete" });
    const state = F.readState(s.sid);
    F.check(`recorded-complete ${stage}: isUnapprovedGatedComplete stays false`,
      isUnapprovedGatedComplete(step, "complete", state, s.sid) === false, "true");
    const eff = reconcileEffectiveState(state, s.sid, { repoDir: s.repo });
    F.check(`recorded-complete ${stage}: effective status stays complete`,
      eff.steps[step] && eff.steps[step].status === "complete", JSON.stringify(eff.steps[step]));
    // An unrelated batch never re-judges the already-complete step.
    const other = F.completeInProcess(s.sid, "workflow_init", s.repo);
    F.check(`recorded-complete ${stage}: an unrelated batch is not refused`, other.ok === true, JSON.stringify(other));
  }
}

function selfRepair() {
  const { reconcileEffectiveState } = require(path.join(F.ROOT, "hooks/workflow-state/effective-state.js"));
  const snapshot = (s) => reconcileEffectiveState(F.readState(s.sid), s.sid, { evidencePolicy: "staged-only", repoDir: s.repo })
    .steps.clarify_intent;

  let s = F.setupStage("repair-none", "intent", F.TERM);
  let snap = snapshot(s);
  F.check("self-repair: approved intent.md without a record stays pending", snap && snap.status === "pending", JSON.stringify(snap));

  s = F.setupStage("repair-rec", "intent", F.TERM);
  const r = F.drift(s.sid, "intent", s.repo);
  F.check("self-repair: check-glossary-drift --record exits 0", r.code === 0, `exit=${r.code} ${r.out}${r.err}`);
  snap = snapshot(s);
  F.check("self-repair: approved intent.md with a valid record resolves complete from evidence",
    snap && snap.status === "complete" && snap.resolved_from === "evidence", JSON.stringify(snap));

  F.touchGlossary(s.repo);
  snap = snapshot(s);
  F.check("self-repair: a stale record no longer resolves clarify_intent", snap && snap.status === "pending", JSON.stringify(snap));
}

module.exports = { sanctioned, alreadyComplete, selfRepair };
