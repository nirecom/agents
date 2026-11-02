"use strict";
// S-C1: the glossary_check record is re-judged at every step status, pending included. A
// pending R-S step whose own targets are staged must not slip through the review_docs
// skip path, the review_tests evidence bypass, or a reason-less pending block.

const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");
const G = require("./gate");

// write_tests resolved from staged tests/ evidence: the review_tests symmetric bypass.
const EVIDENCE_SNAPSHOT = { steps: { write_tests: { status: "complete", resolved_from: "evidence" } } };

// A target of a different R-S step, so the step itself has nothing staged.
const FOREIGN = { review_tests: "review_docs", review_security: "review_tests", review_docs: "review_security" };

function scanOf(step, s) {
  return G.scan(s.sid, s.repo, step === "review_tests" ? { commitSnapshot: EVIDENCE_SNAPSHOT } : {});
}

// The review_tests checker alone takes the evidence bypass, so only the glossary check can block.
function bypassActive(label, s) {
  const { checkReviewTests } = require(path.join(F.ROOT, "hooks/workflow-gate/review-tests-checker.js"));
  const st = F.readState(s.sid).steps.review_tests;
  const own = checkReviewTests("review_tests", st, { docsOnly: false, writeTestsEvidenceBypassed: true, repoDir: s.repo, sessionId: s.sid });
  F.check(`${label}: the review_tests checker alone takes the evidence bypass`, own.action === "skip", JSON.stringify(own));
}

function pendingStaged(step) {
  const label = `gate ${step} pending`;
  const s = F.setupStep(`gate-pend-${step}`, step, F.TERM);
  F.check(`${label}: ${step} reads pending`, F.statusOf(s.sid, step) === "pending", F.statusOf(s.sid, step));
  if (step === "review_tests") bypassActive(label, s);
  G.blocks(`${label} with a ${step} target staged and no record`, scanOf(step, s), step, "glossary-check-missing", true);
  G.recordOk(label, F.drift(s.sid, step, s.repo), 0);
  G.passes(`${label} after --record`, scanOf(step, s), step);
}

function pendingNotStaged(step) {
  const label = `gate ${step} pending with only a ${FOREIGN[step]} target staged`;
  const s = F.setupStep(`gate-pend-none-${step}`, step, F.TERM, { stageTarget: false });
  F.stageFile(s.repo, F.TARGET[FOREIGN[step]], F.targetBody(FOREIGN[step], F.TERM));
  G.passes(label, scanOf(step, s), step);
}

function run() {
  for (const step of F.RS_STEPS) {
    pendingStaged(step);
    pendingNotStaged(step);
  }
}

module.exports = { run };
