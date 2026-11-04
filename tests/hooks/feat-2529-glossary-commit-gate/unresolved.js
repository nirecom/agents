"use strict";
// A current glossary_check record that still holds an ungranted DRIFT finding blocks the commit
// gate with glossary-findings-unresolved; a grant of another term, or of the finding's term at
// another fingerprint, still blocks; the matching grant (F.grantFindings) lets the step pass.

const F = require("../../lib/glossary-check-fixture");
const G = require("./gate");

const ZERO_FP = "0".repeat(64);
const OTHER_NORM = "review scope";

// Replaces the record's grants with `grants` (raw append, as F.grantFindings does).
function setGrants(sid, step, grants) {
  const rec = F.recordOf(sid, step);
  F.appendRaw(sid, [F.annotationEvent(step, "glossary_check", Object.assign({}, rec, { grants }))]);
}

function unresolved(step) {
  const label = `gate ${step} unresolved finding`;
  const s = F.setupStep(`gate-unres-${step}`, step, F.VARIANT, { ownStatus: "complete" });
  if (step === "review_tests") G.recordReviewScope(s.sid, s.repo);
  G.recordOk(label, F.drift(s.sid, step, s.repo), 1);
  const rec = F.recordOf(s.sid, step);
  F.check(`${label}: the current record holds a finding`, !!rec && (rec.findings || []).length > 0, JSON.stringify(rec));

  const reason = G.blocks(`${label}, record current`, G.scan(s.sid, s.repo), step, "glossary-findings-unresolved", true);
  F.check(`${label}: the reason names the unresolved term`, reason.includes(`(${F.TERM})`), reason);

  setGrants(s.sid, step, [{ norm: OTHER_NORM, fingerprint: rec.fingerprint, reason: "fixture grant" }]);
  G.blocks(`${label}, grant of another term`, G.scan(s.sid, s.repo), step, "glossary-findings-unresolved", true);

  F.grantFindings(s.sid, step, ZERO_FP);
  G.blocks(`${label}, grant bound to another fingerprint`, G.scan(s.sid, s.repo), step, "glossary-findings-unresolved", true);

  F.check(`${label}: matching grant written`, F.grantFindings(s.sid, step), "no record to grant");
  G.passes(`${label}, after the matching grant`, G.scan(s.sid, s.repo), step);
}

function run() {
  for (const step of F.RS_STEPS) unresolved(step);
}

module.exports = { run };
