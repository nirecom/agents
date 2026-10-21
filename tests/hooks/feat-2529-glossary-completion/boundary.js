"use strict";
// T6-1: the completion boundary refuses a ->complete transition of any of the 6 glossary
// stages unless the stage's glossary_check record is present, current and resolved.
// matrix() drives the in-process appendEvents boundary; routes() drives each stage's real
// completion route (hook or CLI) once with and once without a record.

const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");

const ZERO_FP = "0".repeat(64);

function expectRefused(label, res, code, sid, step) {
  F.check(`${label}: refused with ${code}`, F.refusedWith(res, code), JSON.stringify(res));
  F.check(`${label}: ${step} is not complete`, F.statusOf(sid, step) !== "complete", F.statusOf(sid, step));
}

function expectCompleted(label, res, sid, step) {
  F.check(`${label}: accepted`, res.ok === true, JSON.stringify(res));
  F.check(`${label}: ${step} is complete`, F.statusOf(sid, step) === "complete", F.statusOf(sid, step));
}

// Exit 1 alone is also what a missing CLI returns, so an unresolved run must print its DRIFT line.
function recordOk(label, r, want) {
  const text = r.out + r.err;
  const ok = r.code === want && (want !== 1 || /DRIFT: \S+ "/.test(text));
  return F.check(`${label}: check-glossary-drift --record exits ${want}`, ok, `exit=${r.code} ${text}`);
}

// One stage, every verdict of evaluateGlossaryCheck through the write boundary.
function matrixFor(stage) {
  const step = F.STAGE_STEP[stage];
  let s = F.setupStage(`missing-${stage}`, stage, F.TERM);
  expectRefused(`${stage} no record`, F.completeInProcess(s.sid, step, s.repo), "glossary-check-missing", s.sid, step);

  s = F.setupStage(`clean-${stage}`, stage, F.TERM);
  recordOk(`${stage} clean`, F.drift(s.sid, stage, s.repo), 0);
  expectCompleted(`${stage} clean record`, F.completeInProcess(s.sid, step, s.repo), s.sid, step);

  s = F.setupStage(`stale-${stage}`, stage, F.TERM);
  recordOk(`${stage} stale`, F.drift(s.sid, stage, s.repo), 0);
  F.touchGlossary(s.repo);
  expectRefused(`${stage} glossary changed after record`, F.completeInProcess(s.sid, step, s.repo),
    "glossary-check-stale", s.sid, step);

  s = F.setupStage(`unresolved-${stage}`, stage, F.VARIANT);
  recordOk(`${stage} unresolved`, F.drift(s.sid, stage, s.repo), 1);
  expectRefused(`${stage} unresolved finding`, F.completeInProcess(s.sid, step, s.repo),
    "glossary-findings-unresolved", s.sid, step);

  s = F.setupStage(`granted-${stage}`, stage, F.VARIANT);
  recordOk(`${stage} granted`, F.drift(s.sid, stage, s.repo), 1);
  F.check(`${stage} granted: grant written`, F.grantFindings(s.sid, stage), "no record to grant");
  expectCompleted(`${stage} finding granted at the record fingerprint`, F.completeInProcess(s.sid, step, s.repo), s.sid, step);

  s = F.setupStage(`oldgrant-${stage}`, stage, F.VARIANT);
  recordOk(`${stage} old grant`, F.drift(s.sid, stage, s.repo), 1);
  F.grantFindings(s.sid, stage, ZERO_FP);
  expectRefused(`${stage} grant bound to another fingerprint`, F.completeInProcess(s.sid, step, s.repo),
    "glossary-findings-unresolved", s.sid, step);

  if (!F.RS_STAGES.includes(stage)) return;
  s = F.setupStage(`empty-${stage}`, stage, F.TERM, { stageTarget: false });
  expectRefused(`${stage} empty target, no record`, F.completeInProcess(s.sid, step, s.repo),
    "glossary-check-missing", s.sid, step);
  recordOk(`${stage} empty target`, F.drift(s.sid, stage, s.repo), 0);
  const rec = F.recordOf(s.sid, stage);
  F.check(`${stage} empty target: record has no findings`, !!rec && Array.isArray(rec.findings) && rec.findings.length === 0,
    JSON.stringify(rec));
  expectCompleted(`${stage} empty target with an empty-target record`, F.completeInProcess(s.sid, step, s.repo), s.sid, step);
}

function matrix() {
  for (const stage of F.STAGES) matrixFor(stage);
}

// Review-scope fingerprint the REVIEW_TESTS_COMPLETE handler re-derives from the index.
function reviewScopeFp(repo) {
  const ev = require(path.join(F.ROOT, "hooks/workflow-gate/review-tests-evidence.js"));
  const m = ev.computeReviewScopeManifest(repo);
  return m.ok ? ev.fingerprintOfManifest(m.files) : "unavailable";
}

const ROUTES = {
  intent: [["CLARIFY_INTENT_COMPLETE", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"', repo)]],
  outline: [["MARK_STEP", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_MARK_STEP_outline_complete>>"', repo)],
    ["next-step --advance", (sid, repo) => F.advance(sid, "outline", repo)]],
  detail: [["MARK_STEP", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_MARK_STEP_detail_complete>>"', repo)],
    ["next-step --advance", (sid, repo) => F.advance(sid, "detail", repo)]],
  tests: [["REVIEW_TESTS_COMPLETE", (sid, repo) =>
    F.mark(sid, `echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=${reviewScopeFp(repo)}>>"`, repo)]],
  code: [["MARK_STEP", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_MARK_STEP_review_security_complete>>"', repo)],
    ["next-step --advance", (sid, repo) => F.advance(sid, "review_security", repo)]],
  docs: [["MARK_STEP", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_MARK_STEP_review_docs_complete>>"', repo)],
    ["next-step --advance", (sid, repo) => F.advance(sid, "review_docs", repo)]],
};

function routes() {
  for (const stage of F.STAGES) {
    const step = F.STAGE_STEP[stage];
    for (const [name, run] of ROUTES[stage]) {
      let s = F.setupStage(`route-none-${stage}`, stage, F.TERM);
      const r = run(s.sid, s.repo);
      const text = r.out + r.err;
      F.check(`${stage} via ${name} without a record: not complete`, F.statusOf(s.sid, step) !== "complete",
        `status=${F.statusOf(s.sid, step)}`);
      F.check(`${stage} via ${name} without a record: names glossary-check-missing and the recovery`,
        text.includes("glossary-check-missing") && text.includes(`check-glossary-drift`) && text.includes(`--stage ${stage}`), text);

      s = F.setupStage(`route-rec-${stage}`, stage, F.TERM);
      recordOk(`${stage} via ${name}`, F.drift(s.sid, stage, s.repo), 0);
      const r2 = run(s.sid, s.repo);
      F.check(`${stage} via ${name} with a clean record: complete`, F.statusOf(s.sid, step) === "complete",
        `status=${F.statusOf(s.sid, step)} exit=${r2.code} ${r2.out}${r2.err}`);
    }
  }
}

module.exports = { matrix, routes };
