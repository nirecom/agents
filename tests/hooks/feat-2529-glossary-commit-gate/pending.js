"use strict";
// S-C1: the glossary_check record is re-judged at every step status, pending included. A
// pending R-S step whose stage targets are staged must not slip through the review_docs
// skip path, the review_tests evidence bypass, or a reason-less pending block.

const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");
const G = require("./gate");

// write_tests resolved from staged tests/ evidence: the review_tests symmetric bypass.
const EVIDENCE_SNAPSHOT = { steps: { write_tests: { status: "complete", resolved_from: "evidence" } } };

// A target of a different R-S stage, so the step's own stage has nothing staged.
const FOREIGN = { tests: "docs", code: "tests", docs: "code" };

function scanOf(stage, s) {
  return G.scan(s.sid, s.repo, stage === "tests" ? { commitSnapshot: EVIDENCE_SNAPSHOT } : {});
}

// The review_tests checker alone takes the evidence bypass, so only the glossary check can block.
function bypassActive(label, s) {
  const { checkReviewTests } = require(path.join(F.ROOT, "hooks/workflow-gate/review-tests-checker.js"));
  const st = F.readState(s.sid).steps.review_tests;
  const own = checkReviewTests("review_tests", st, { docsOnly: false, writeTestsEvidenceBypassed: true, repoDir: s.repo, sessionId: s.sid });
  F.check(`${label}: the review_tests checker alone takes the evidence bypass`, own.action === "skip", JSON.stringify(own));
}

function pendingStaged(stage) {
  const step = F.STAGE_STEP[stage];
  const label = `gate ${stage} pending`;
  const s = F.setupStage(`gate-pend-${stage}`, stage, F.TERM);
  F.check(`${label}: ${step} reads pending`, F.statusOf(s.sid, step) === "pending", F.statusOf(s.sid, step));
  if (stage === "tests") bypassActive(label, s);
  G.blocks(`${label} with a ${stage} target staged and no record`, scanOf(stage, s), step, "glossary-check-missing", stage);
  G.recordOk(label, F.drift(s.sid, stage, s.repo), 0);
  G.passes(`${label} after --record`, scanOf(stage, s), step);
}

function pendingNotStaged(stage) {
  const step = F.STAGE_STEP[stage];
  const label = `gate ${stage} pending with only a ${FOREIGN[stage]} target staged`;
  const s = F.setupStage(`gate-pend-none-${stage}`, stage, F.TERM, { stageTarget: false });
  F.stageFile(s.repo, F.TARGET[FOREIGN[stage]], F.targetBody(FOREIGN[stage], F.TERM));
  G.passes(label, scanOf(stage, s), step);
}

function run() {
  for (const stage of F.RS_STAGES) {
    pendingStaged(stage);
    pendingNotStaged(stage);
  }
}

module.exports = { run };
