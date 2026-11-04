"use strict";
// T6-6: a staged-blob swap under a valid record blocks at the commit gate even though the
// working tree is restored to the recorded content (a working-tree reader would pass it).
// T7-6: with the index untouched, a change to the main worktree's combined glossary alone
// blocks glossary-check-stale and the reason names the glossary component.

const F = require("../../lib/glossary-check-fixture");
const G = require("./gate");

const ALT = { review_tests: "each staged line", review_security: "each staged line", review_docs: "each staged line" };

// The reason with the code and recovery text removed, so a component name is not matched
// inside "glossary-check-stale" or "check-glossary-drift".
const componentText = (reason) => String(reason).replace(/glossary-check-stale|check-glossary-drift/g, "");

function blobSwap(step) {
  const label = `blob swap ${step}`;
  const s = G.completedStep(`swap-${step}`, step);
  G.recordOk(label, F.drift(s.sid, step, s.repo), 0);
  G.passes(`${label}: recorded content A staged`, G.scan(s.sid, s.repo), step);

  const contentA = F.targetBody(step, F.TERM);
  F.stageFile(s.repo, F.TARGET[step], F.targetBody(step, ALT[step]));
  F.writeFile(s.repo, F.TARGET[step], contentA);
  const reason = G.blocks(`${label}: B staged, working tree back to A`, G.scan(s.sid, s.repo), step, "glossary-check-stale", true);
  F.check(`${label}: the reason names the artifact component`, /\bartifact\b/.test(componentText(reason)), reason);

  G.recordOk(`${label} re-record`, F.drift(s.sid, step, s.repo), 0);
  G.passes(`${label}: after re-record of blob B`, G.scan(s.sid, s.repo), step);
}

function glossaryOnly(step) {
  const label = `glossary input ${step}`;
  const s = G.completedStep(`ginput-${step}`, step);
  G.recordOk(label, F.drift(s.sid, step, s.repo), 0);
  G.passes(`${label}: record current`, G.scan(s.sid, s.repo), step);
  F.touchGlossary(s.repo);
  const reason = G.blocks(`${label}: main glossary changed, index untouched`, G.scan(s.sid, s.repo), step,
    "glossary-check-stale", true);
  const text = componentText(reason);
  F.check(`${label}: the reason names the glossary component`, /\bglossary\b/.test(text), reason);
  F.check(`${label}: the reason does not name the artifact component`, !/\bartifact\b/.test(text), reason);
  G.recordOk(`${label} re-record`, F.drift(s.sid, step, s.repo), 0);
  G.passes(`${label}: after re-record`, G.scan(s.sid, s.repo), step);
}

// #2909: with a granted finding, the glossary-only stale reason names the term whose grant lapses.
function glossaryOnlyGranted(step) {
  const label = `glossary input ${step} with a grant`;
  const s = F.setupStep(`ginput-g-${step}`, step, F.VARIANT, { ownStatus: "complete" });
  if (step === "review_tests") G.recordReviewScope(s.sid, s.repo);
  G.recordOk(label, F.drift(s.sid, step, s.repo), 1);
  F.check(`${label}: grant written`, F.grantFindings(s.sid, step), "no record to grant");
  G.passes(`${label}: record current and granted`, G.scan(s.sid, s.repo), step);
  F.touchGlossary(s.repo);
  const reason = G.blocks(`${label}: main glossary changed`, G.scan(s.sid, s.repo), step, "glossary-check-stale", true);
  F.check(`${label}: the reason names the term whose grant lapses`,
    reason.includes(`the grants for ${F.TERM} lapse`) && reason.includes(`term=${F.TERM} step=${step}`), reason);
  F.check(`${label}: the reason does not name the artifact component`, !/\bartifact\b/.test(componentText(reason)), reason);
}

function run() {
  for (const step of F.RS_STEPS) {
    blobSwap(step);
    glossaryOnly(step);
    glossaryOnlyGranted(step);
  }
}

module.exports = { run };
