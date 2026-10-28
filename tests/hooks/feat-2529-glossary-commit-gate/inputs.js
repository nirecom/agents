"use strict";
// T6-6: a staged-blob swap under a valid record blocks at the commit gate even though the
// working tree is restored to the recorded content (a working-tree reader would pass it).
// T7-6: with the index untouched, a change to the main worktree's combined glossary alone
// blocks glossary-check-stale and the reason names the glossary component.

const F = require("../../lib/glossary-check-fixture");
const G = require("./gate");

const ALT = { tests: "each staged line", code: "each staged line", docs: "each staged line" };

// The reason with the code and recovery text removed, so a component name is not matched
// inside "glossary-check-stale" or "check-glossary-drift".
const componentText = (reason) => String(reason).replace(/glossary-check-stale|check-glossary-drift/g, "");

function blobSwap(stage) {
  const step = F.STAGE_STEP[stage];
  const label = `blob swap ${stage}`;
  const s = G.completedStage(`swap-${stage}`, stage);
  G.recordOk(label, F.drift(s.sid, stage, s.repo), 0);
  G.passes(`${label}: recorded content A staged`, G.scan(s.sid, s.repo), step);

  const contentA = F.targetBody(stage, F.TERM);
  F.stageFile(s.repo, F.TARGET[stage], F.targetBody(stage, ALT[stage]));
  F.writeFile(s.repo, F.TARGET[stage], contentA);
  const reason = G.blocks(`${label}: B staged, working tree back to A`, G.scan(s.sid, s.repo), step, "glossary-check-stale", stage);
  F.check(`${label}: the reason names the artifact component`, /\bartifact\b/.test(componentText(reason)), reason);

  G.recordOk(`${label} re-record`, F.drift(s.sid, stage, s.repo), 0);
  G.passes(`${label}: after re-record of blob B`, G.scan(s.sid, s.repo), step);
}

function glossaryOnly(stage) {
  const step = F.STAGE_STEP[stage];
  const label = `glossary input ${stage}`;
  const s = G.completedStage(`ginput-${stage}`, stage);
  G.recordOk(label, F.drift(s.sid, stage, s.repo), 0);
  G.passes(`${label}: record current`, G.scan(s.sid, s.repo), step);
  F.touchGlossary(s.repo);
  const reason = G.blocks(`${label}: main glossary changed, index untouched`, G.scan(s.sid, s.repo), step,
    "glossary-check-stale", stage);
  const text = componentText(reason);
  F.check(`${label}: the reason names the glossary component`, /\bglossary\b/.test(text), reason);
  F.check(`${label}: the reason does not name the artifact component`, !/\bartifact\b/.test(text), reason);
  G.recordOk(`${label} re-record`, F.drift(s.sid, stage, s.repo), 0);
  G.passes(`${label}: after re-record`, G.scan(s.sid, s.repo), step);
}

function run() {
  for (const stage of F.RS_STAGES) {
    blobSwap(stage);
    glossaryOnly(stage);
  }
}

module.exports = { run };
