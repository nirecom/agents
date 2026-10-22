"use strict";
// A current glossary_check record that still holds an ungranted DRIFT finding blocks the commit
// gate with glossary-findings-unresolved; a grant of another term, or of the finding's term at
// another fingerprint, still blocks; the matching grant (F.grantFindings) lets the step pass.

const F = require("../../lib/glossary-check-fixture");
const G = require("./gate");

const ZERO_FP = "0".repeat(64);
const OTHER_NORM = "review scope";

// Replaces the record's grants with `grants` (raw append, as F.grantFindings does).
function setGrants(sid, stage, grants) {
  const rec = F.recordOf(sid, stage);
  F.appendRaw(sid, [F.annotationEvent(F.STAGE_STEP[stage], "glossary_check", Object.assign({}, rec, { grants }))]);
}

function unresolved(stage) {
  const step = F.STAGE_STEP[stage];
  const label = `gate ${stage} unresolved finding`;
  const s = F.setupStage(`gate-unres-${stage}`, stage, F.VARIANT, { ownStatus: "complete" });
  if (stage === "tests") G.recordReviewScope(s.sid, s.repo);
  G.recordOk(label, F.drift(s.sid, stage, s.repo), 1);
  const rec = F.recordOf(s.sid, stage);
  F.check(`${label}: the current record holds a finding`, !!rec && (rec.findings || []).length > 0, JSON.stringify(rec));

  const reason = G.blocks(`${label}, record current`, G.scan(s.sid, s.repo), step, "glossary-findings-unresolved", stage);
  F.check(`${label}: the reason counts the unresolved finding`, /\(1 unresolved finding\(s\)\)/.test(reason), reason);

  setGrants(s.sid, stage, [{ norm: OTHER_NORM, fingerprint: rec.fingerprint, reason: "fixture grant" }]);
  G.blocks(`${label}, grant of another term`, G.scan(s.sid, s.repo), step, "glossary-findings-unresolved", stage);

  F.grantFindings(s.sid, stage, ZERO_FP);
  G.blocks(`${label}, grant bound to another fingerprint`, G.scan(s.sid, s.repo), step, "glossary-findings-unresolved", stage);

  F.check(`${label}: matching grant written`, F.grantFindings(s.sid, stage), "no record to grant");
  G.passes(`${label}, after the matching grant`, G.scan(s.sid, s.repo), step);
}

function run() {
  for (const stage of F.RS_STAGES) unresolved(stage);
}

module.exports = { run };
