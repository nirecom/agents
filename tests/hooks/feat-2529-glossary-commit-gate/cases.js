"use strict";
// T6-5: the commit gate re-judges each R-S step's glossary_check record against the CURRENT
// staged set, for complete AND skipped steps, inside a linked worktree too, and before every
// early continue of the step scan (review_tests / review_docs checkers, status complete/skipped).

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");
const G = require("./gate");

const SECOND = { tests: "tests/t2.sh", code: "src/b.js", docs: "docs/guide2.md" };
const GATED = Object.values(F.STAGE_STEP).filter((s) => ["review_tests", "review_security", "review_docs"].includes(s));

// No step outside the three R-S steps ever carries a glossary-* reason.
function othersClean(label, r) {
  const bad = Object.entries(r.incompleteReasons || {})
    .filter(([step, reason]) => !GATED.includes(step) && F.GLOSSARY_CODES.test(String(reason)));
  F.check(`${label}: no other step carries a glossary reason`, !r.threw && bad.length === 0, r.threw || JSON.stringify(bad));
}

function completeAndChanged(stage) {
  const step = F.STAGE_STEP[stage];
  const label = `gate ${stage}`;
  const s = G.completedStage(`gate-${stage}`, stage);
  G.blocks(`${label} complete without a record`, G.scan(s.sid, s.repo), step, "glossary-check-missing", stage);
  G.recordOk(label, F.drift(s.sid, stage, s.repo), 0);
  if (stage === "tests") G.recordReviewScope(s.sid, s.repo);
  let r = G.scan(s.sid, s.repo);
  G.passes(`${label} with a current record`, r, step);
  othersClean(label, r);
  F.stageFile(s.repo, SECOND[stage], F.targetBody(stage, F.TERM));
  if (stage === "tests") G.recordReviewScope(s.sid, s.repo);
  G.blocks(`${label} another target staged after the record`, G.scan(s.sid, s.repo), step, "glossary-check-stale", stage);
  F.stageFile(s.repo, F.TARGET[stage], F.targetBody(stage, "each fixture line"));
  if (stage === "tests") G.recordReviewScope(s.sid, s.repo);
  G.blocks(`${label} staged target content changed`, G.scan(s.sid, s.repo), step, "glossary-check-stale", stage);
  G.recordOk(`${label} re-record`, F.drift(s.sid, stage, s.repo), 0);
  G.passes(`${label} after re-record`, G.scan(s.sid, s.repo), step);
}

function linkedWorktree(stage) {
  const step = F.STAGE_STEP[stage];
  const label = `gate ${stage} in a linked worktree`;
  const repo = F.mkRepo(`gate-wt-${stage}`);
  const wt = F.addWorktree(repo, `${stage}-${process.pid}`);
  F.stageFile(wt, F.TARGET[stage], F.targetBody(stage, F.TERM));
  const sid = F.seedSession(`gate-wt-${stage}`, stage, { ownStatus: "complete", cwd: wt });
  if (stage === "tests") G.recordReviewScope(sid, wt);
  G.blocks(`${label} without a record`, G.scan(sid, wt), step, "glossary-check-missing", stage);
  G.recordOk(label, F.drift(sid, stage, wt), 0);
  G.passes(`${label} with a current record`, G.scan(sid, wt), step);
  F.stageFile(wt, SECOND[stage], F.targetBody(stage, F.TERM));
  if (stage === "tests") G.recordReviewScope(sid, wt);
  G.blocks(`${label} after a new target`, G.scan(sid, wt), step, "glossary-check-stale", stage);
}

function unavailable(stage) {
  const step = F.STAGE_STEP[stage];
  const s = G.completedStage(`gate-unav-${stage}`, stage);
  F.drift(s.sid, stage, s.repo);
  const notGit = F.slash(fs.mkdtempSync(path.join(os.tmpdir(), "g2529-notgit-")));
  G.blocks(`gate ${stage} with an unreadable repository`, G.scan(s.sid, notGit), step, "glossary-fingerprint-unavailable");
}

function skipped(stage) {
  const step = F.STAGE_STEP[stage];
  const label = `gate ${stage} skipped`;
  let s = F.setupStage(`gate-skip-${stage}`, stage, F.TERM);
  F.check(`${label}: ${step} reads skipped`, G.skipStep(s.sid, step, s.repo), F.statusOf(s.sid, step));
  G.blocks(`${label} with a ${stage} target staged and no record`, G.scan(s.sid, s.repo), step, "glossary-check-missing", stage);
  G.recordOk(label, F.drift(s.sid, stage, s.repo), 0);
  G.passes(`${label} after --record`, G.scan(s.sid, s.repo), step);

  s = F.setupStage(`gate-skip-none-${stage}`, stage, F.TERM, { stageTarget: false });
  G.skipStep(s.sid, step, s.repo);
  G.passes(`${label} with no ${stage} target staged`, G.scan(s.sid, s.repo), step);
}

function docsOnly() {
  const s = G.completedStage("gate-docsonly", "docs");
  G.recordOk("gate docs-only", F.drift(s.sid, "docs", s.repo), 0);
  G.passes("gate docs-only commit with a current record", G.scan(s.sid, s.repo, { docsOnly: true }), "review_docs");
  F.stageFile(s.repo, SECOND.docs, F.targetBody("docs", F.TERM));
  G.blocks("gate docs-only commit with another docs file staged", G.scan(s.sid, s.repo, { docsOnly: true }),
    "review_docs", "glossary-check-stale", "docs");
}

function wfMeta() {
  const s = F.setupStage("gate-wfmeta", "docs", F.TERM, { stageTarget: false, deliverableType: "wf-meta" });
  for (const step of GATED) F.appendRaw(s.sid, [F.stepStatusEvent(step, "skipped")]);
  let r = G.scan(s.sid, s.repo);
  for (const step of GATED) G.passes("gate wf-meta with an empty index", r, step);
  F.stageFile(s.repo, "docs/meta.md", "# Meta\n");
  r = G.scan(s.sid, s.repo);
  for (const step of ["review_tests", "review_security"]) G.passes("gate wf-meta with only a docs file staged", r, step);
  othersClean("gate wf-meta", r);
}

// review_tests' own checker approves (current review scope) yet the glossary block still lands.
function ordering() {
  const s = G.completedStage("gate-order", "tests");
  const { checkReviewTests } = require(path.join(F.ROOT, "hooks/workflow-gate/review-tests-checker.js"));
  const st = F.readState(s.sid).steps.review_tests;
  const own = checkReviewTests("review_tests", st, { docsOnly: false, writeTestsEvidenceBypassed: false, repoDir: s.repo, sessionId: s.sid });
  F.check("gate ordering: the review_tests checker alone approves", own.action === "skip", JSON.stringify(own));
  G.blocks("gate ordering: review_tests checker approves, record missing", G.scan(s.sid, s.repo),
    "review_tests", "glossary-check-missing", "tests");
}

function runStages(stages) {
  for (const stage of stages) {
    completeAndChanged(stage);
    linkedWorktree(stage);
    unavailable(stage);
    skipped(stage);
  }
}

function runCommitShapes() {
  docsOnly();
  wfMeta();
  ordering();
}

// The stages and the commit shapes are entered separately so the case can span two entrypoints.
module.exports = { runStages, runCommitShapes, SECOND };
