"use strict";
// T6-2: an inheritance copy (origin session-inherit) and a RESET_FROM batch are not judged by the
// glossary boundary, "reset-sentinel" is no longer a caller-passable token (#2709), and a step already recorded complete is not reverted for a missing record.
// T6-3: the early-gate snapshot (evidencePolicy "staged-only") resolves an approved pending
// clarify_intent to complete only when its glossary_check record is valid.

const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");

function sanctioned() {
  for (const step of F.GLOSSARY_STEPS) {
    const s = F.setupStep(`sanct-${step}`, step, F.VARIANT);
    const res = F.completeInProcess(s.sid, step, s.repo, { origin: "session-inherit", provenance: "backfilled" });
    F.check(`session-inherit ${step}: no glossary refusal without a record`, res.ok === true, JSON.stringify(res));
    F.check(`session-inherit ${step}: ${step} is complete`, F.statusOf(s.sid, step) === "complete", F.statusOf(s.sid, step));
  }
  // A RESET_FROM batch (its `reset` anchor) re-completes a prior step without a glossary record.
  const { appendEvents } = require(path.join(F.ROOT, "hooks/workflow-state/state-io/events.js"));
  for (const step of F.GLOSSARY_STEPS) {
    const s = F.setupStep(`sanct-resetbatch-${step}`, step, F.VARIANT);
    const prev = process.cwd();
    let res;
    process.chdir(s.repo);
    try {
      appendEvents(s.sid, [
        { kind: "reset", from_step: "workflow_init", reason: "fixture reset", provenance: "declared", origin: "reset-sentinel" },
        { kind: "step_status", step, status: "complete", provenance: "declared", origin: "reset-sentinel" },
      ]);
      res = { ok: true };
    } catch (e) {
      res = { ok: false, code: e && e.code, message: String((e && e.message) || e) };
    } finally {
      process.chdir(prev);
    }
    F.check(`reset batch ${step}: no glossary refusal without a record`, res.ok === true, JSON.stringify(res));
    F.check(`reset batch ${step}: ${step} is complete`, F.statusOf(s.sid, step) === "complete", F.statusOf(s.sid, step));
  }
  // #2709: "reset-sentinel" is no longer a caller-passable sanctioned token.
  const step = F.GLOSSARY_STEPS[0];
  const s = F.setupStep(`sanct-reset-${step}`, step, F.VARIANT);
  const res = F.completeInProcess(s.sid, step, s.repo, { sanctioned: "reset-sentinel", reason: "fixture" });
  F.check(`reset-sentinel ${step}: the token is refused`, F.refusedWith(res, "unknown-sanctioned-token"), JSON.stringify(res));
  F.check(`reset-sentinel ${step}: ${step} stays not complete`, F.statusOf(s.sid, step) !== "complete", F.statusOf(s.sid, step));
}

// A step recorded complete before the glossary predicate existed keeps reading complete.
function alreadyComplete() {
  const { reconcileEffectiveState, isUnapprovedGatedComplete } = require(path.join(F.ROOT, "hooks/workflow-state/effective-state.js"));
  for (const step of F.GLOSSARY_STEPS) {
    const s = F.setupStep(`done-${step}`, step, F.VARIANT, { ownStatus: "complete" });
    const state = F.readState(s.sid);
    F.check(`recorded-complete ${step}: isUnapprovedGatedComplete stays false`,
      isUnapprovedGatedComplete(step, "complete", state, s.sid) === false, "true");
    const eff = reconcileEffectiveState(state, s.sid, { repoDir: s.repo });
    F.check(`recorded-complete ${step}: effective status stays complete`,
      eff.steps[step] && eff.steps[step].status === "complete", JSON.stringify(eff.steps[step]));
    // An unrelated batch never re-judges the already-complete step.
    const other = F.completeInProcess(s.sid, "workflow_init", s.repo);
    F.check(`recorded-complete ${step}: an unrelated batch is not refused`, other.ok === true, JSON.stringify(other));
  }
}

function selfRepair() {
  const { reconcileEffectiveState } = require(path.join(F.ROOT, "hooks/workflow-state/effective-state.js"));
  const snapshot = (s) => reconcileEffectiveState(F.readState(s.sid), s.sid, { evidencePolicy: "staged-only", repoDir: s.repo })
    .steps.clarify_intent;

  let s = F.setupStep("repair-none", "clarify_intent", F.TERM);
  let snap = snapshot(s);
  F.check("self-repair: approved intent.md without a record stays pending", snap && snap.status === "pending", JSON.stringify(snap));

  s = F.setupStep("repair-rec", "clarify_intent", F.TERM);
  const r = F.drift(s.sid, "clarify_intent", s.repo);
  F.check("self-repair: check-glossary-drift --record exits 0", r.code === 0, `exit=${r.code} ${r.out}${r.err}`);
  snap = snapshot(s);
  F.check("self-repair: approved intent.md with a valid record resolves complete from evidence",
    snap && snap.status === "complete" && snap.resolved_from === "evidence", JSON.stringify(snap));

  F.addDriftingEntry(s.repo);
  snap = snapshot(s);
  F.check("self-repair: a stale record no longer resolves clarify_intent", snap && snap.status === "pending", JSON.stringify(snap));
}

module.exports = { sanctioned, alreadyComplete, selfRepair };
