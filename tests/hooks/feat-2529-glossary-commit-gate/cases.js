"use strict";
// T6-5: the commit gate re-judges each R-S step's glossary_check record against the CURRENT
// staged set, for complete AND skipped steps, inside a linked worktree too, and before every
// early continue of the step scan (review_tests / review_docs checkers, status complete/skipped).

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");
const G = require("./gate");

const SECOND = { review_tests: "tests/t2.sh", review_security: "src/b.js", review_docs: "docs/guide2.md" };
const GATED = F.RS_STEPS.filter((s) => ["review_tests", "review_security", "review_docs"].includes(s));

// No step outside the three R-S steps ever carries a glossary-* reason.
function othersClean(label, r) {
  const bad = Object.entries(r.incompleteReasons || {})
    .filter(([step, reason]) => !GATED.includes(step) && F.GLOSSARY_CODES.test(String(reason)));
  F.check(`${label}: no other step carries a glossary reason`, !r.threw && bad.length === 0, r.threw || JSON.stringify(bad));
}

function completeAndChanged(step) {
  const label = `gate ${step}`;
  const s = G.completedStep(`gate-${step}`, step);
  G.blocks(`${label} complete without a record`, G.scan(s.sid, s.repo), step, "glossary-check-missing", true);
  G.recordOk(label, F.drift(s.sid, step, s.repo), 0);
  if (step === "review_tests") G.recordReviewScope(s.sid, s.repo);
  let r = G.scan(s.sid, s.repo);
  G.passes(`${label} with a current record`, r, step);
  othersClean(label, r);
  F.stageFile(s.repo, SECOND[step], F.targetBody(step, F.TERM));
  if (step === "review_tests") G.recordReviewScope(s.sid, s.repo);
  G.blocks(`${label} another target staged after the record`, G.scan(s.sid, s.repo), step, "glossary-check-stale", true);
  F.stageFile(s.repo, F.TARGET[step], F.targetBody(step, "each fixture line"));
  if (step === "review_tests") G.recordReviewScope(s.sid, s.repo);
  G.blocks(`${label} staged target content changed`, G.scan(s.sid, s.repo), step, "glossary-check-stale", true);
  G.recordOk(`${label} re-record`, F.drift(s.sid, step, s.repo), 0);
  G.passes(`${label} after re-record`, G.scan(s.sid, s.repo), step);
}

function linkedWorktree(step) {
  const label = `gate ${step} in a linked worktree`;
  const repo = F.mkRepo(`gate-wt-${step}`);
  const wt = F.addWorktree(repo, `${step}-${process.pid}`);
  F.stageFile(wt, F.TARGET[step], F.targetBody(step, F.TERM));
  const sid = F.seedSession(`gate-wt-${step}`, step, { ownStatus: "complete", cwd: wt });
  if (step === "review_tests") G.recordReviewScope(sid, wt);
  G.blocks(`${label} without a record`, G.scan(sid, wt), step, "glossary-check-missing", true);
  G.recordOk(label, F.drift(sid, step, wt), 0);
  G.passes(`${label} with a current record`, G.scan(sid, wt), step);
  F.stageFile(wt, SECOND[step], F.targetBody(step, F.TERM));
  if (step === "review_tests") G.recordReviewScope(sid, wt);
  G.blocks(`${label} after a new target`, G.scan(sid, wt), step, "glossary-check-stale", true);
}

function unavailable(step) {
  const s = G.completedStep(`gate-unav-${step}`, step);
  F.drift(s.sid, step, s.repo);
  const notGit = F.slash(fs.mkdtempSync(path.join(os.tmpdir(), "g2529-notgit-")));
  G.blocks(`gate ${step} with an unreadable repository`, G.scan(s.sid, notGit), step, "glossary-fingerprint-unavailable");
}

function skipped(step) {
  const label = `gate ${step} skipped`;
  let s = F.setupStep(`gate-skip-${step}`, step, F.TERM);
  F.check(`${label}: ${step} reads skipped`, G.skipStep(s.sid, step, s.repo), F.statusOf(s.sid, step));
  G.blocks(`${label} with a ${step} target staged and no record`, G.scan(s.sid, s.repo), step, "glossary-check-missing", true);
  G.recordOk(label, F.drift(s.sid, step, s.repo), 0);
  G.passes(`${label} after --record`, G.scan(s.sid, s.repo), step);

  s = F.setupStep(`gate-skip-none-${step}`, step, F.TERM, { stageTarget: false });
  G.skipStep(s.sid, step, s.repo);
  G.passes(`${label} with no ${step} target staged`, G.scan(s.sid, s.repo), step);
}

function docsOnly() {
  const s = G.completedStep("gate-docsonly", "review_docs");
  G.recordOk("gate docs-only", F.drift(s.sid, "review_docs", s.repo), 0);
  G.passes("gate docs-only commit with a current record", G.scan(s.sid, s.repo, { docsOnly: true }), "review_docs");
  F.stageFile(s.repo, SECOND.review_docs, F.targetBody("review_docs", F.TERM));
  G.blocks("gate docs-only commit with another docs file staged", G.scan(s.sid, s.repo, { docsOnly: true }),
    "review_docs", "glossary-check-stale", true);
}

function wfMeta() {
  const s = F.setupStep("gate-wfmeta", "review_docs", F.TERM, { stageTarget: false, deliverableType: "wf-meta" });
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
  const s = G.completedStep("gate-order", "review_tests");
  const { checkReviewTests } = require(path.join(F.ROOT, "hooks/workflow-gate/review-tests-checker.js"));
  const st = F.readState(s.sid).steps.review_tests;
  const own = checkReviewTests("review_tests", st, { docsOnly: false, writeTestsEvidenceBypassed: false, repoDir: s.repo, sessionId: s.sid });
  F.check("gate ordering: the review_tests checker alone approves", own.action === "skip", JSON.stringify(own));
  G.blocks("gate ordering: review_tests checker approves, record missing", G.scan(s.sid, s.repo),
    "review_tests", "glossary-check-missing", true);
}

function runSteps(steps) {
  for (const step of steps) {
    completeAndChanged(step);
    linkedWorktree(step);
    unavailable(step);
    skipped(step);
  }
}

function runCommitShapes() {
  docsOnly();
  wfMeta();
  ordering();
}

// The steps and the commit shapes are entered separately so the case can span two entrypoints.
module.exports = { runSteps, runCommitShapes, SECOND };
