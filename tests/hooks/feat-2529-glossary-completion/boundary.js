"use strict";
// T6-1: the completion boundary refuses a ->complete transition of any of the 6 glossary
// steps unless the step's glossary_check record is present, current and resolved.
// matrix() drives the in-process appendEvents boundary; routes() drives each step's real
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

// One step, every verdict of evaluateGlossaryCheck through the write boundary.
function matrixFor(step) {
  let s = F.setupStep(`missing-${step}`, step, F.TERM);
  expectRefused(`${step} no record`, F.completeInProcess(s.sid, step, s.repo), "glossary-check-missing", s.sid, step);

  s = F.setupStep(`clean-${step}`, step, F.TERM);
  recordOk(`${step} clean`, F.drift(s.sid, step, s.repo), 0);
  expectCompleted(`${step} clean record`, F.completeInProcess(s.sid, step, s.repo), s.sid, step);

  s = F.setupStep(`stale-${step}`, step, F.TERM);
  recordOk(`${step} stale`, F.drift(s.sid, step, s.repo), 0);
  F.addDriftingEntry(s.repo);
  expectRefused(`${step} glossary changed after record`, F.completeInProcess(s.sid, step, s.repo),
    "glossary-check-stale", s.sid, step);

  s = F.setupStep(`unresolved-${step}`, step, F.VARIANT);
  recordOk(`${step} unresolved`, F.drift(s.sid, step, s.repo), 1);
  expectRefused(`${step} unresolved finding`, F.completeInProcess(s.sid, step, s.repo),
    "glossary-findings-unresolved", s.sid, step);

  s = F.setupStep(`granted-${step}`, step, F.VARIANT);
  recordOk(`${step} granted`, F.drift(s.sid, step, s.repo), 1);
  F.check(`${step} granted: grant written`, F.grantFindings(s.sid, step), "no record to grant");
  expectCompleted(`${step} finding granted at the record fingerprint`, F.completeInProcess(s.sid, step, s.repo), s.sid, step);

  s = F.setupStep(`oldgrant-${step}`, step, F.VARIANT);
  recordOk(`${step} old grant`, F.drift(s.sid, step, s.repo), 1);
  F.grantFindings(s.sid, step, ZERO_FP);
  expectRefused(`${step} grant bound to another fingerprint`, F.completeInProcess(s.sid, step, s.repo),
    "glossary-findings-unresolved", s.sid, step);

  if (!F.RS_STEPS.includes(step)) return;
  s = F.setupStep(`empty-${step}`, step, F.TERM, { stageTarget: false });
  expectRefused(`${step} empty target, no record`, F.completeInProcess(s.sid, step, s.repo),
    "glossary-check-missing", s.sid, step);
  recordOk(`${step} empty target`, F.drift(s.sid, step, s.repo), 0);
  const rec = F.recordOf(s.sid, step);
  F.check(`${step} empty target: record has no findings`, !!rec && Array.isArray(rec.findings) && rec.findings.length === 0,
    JSON.stringify(rec));
  expectCompleted(`${step} empty target with an empty-target record`, F.completeInProcess(s.sid, step, s.repo), s.sid, step);
}

function matrix() {
  for (const step of F.GLOSSARY_STEPS) matrixFor(step);
}

// Review-scope fingerprint the REVIEW_TESTS_COMPLETE handler re-derives from the index.
function reviewScopeFp(repo) {
  const ev = require(path.join(F.ROOT, "hooks/workflow-gate/review-tests-evidence.js"));
  const m = ev.computeReviewScopeManifest(repo);
  return m.ok ? ev.fingerprintOfManifest(m.files) : "unavailable";
}

const ROUTES = {
  clarify_intent: [["CLARIFY_INTENT_COMPLETE", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"', repo)]],
  outline: [["MARK_STEP", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_MARK_STEP_outline_complete>>"', repo)],
    ["next-step --advance", (sid, repo) => F.advance(sid, "outline", repo)]],
  detail: [["MARK_STEP", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_MARK_STEP_detail_complete>>"', repo)],
    ["next-step --advance", (sid, repo) => F.advance(sid, "detail", repo)]],
  review_tests: [["REVIEW_TESTS_COMPLETE", (sid, repo) =>
    F.mark(sid, `echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=${reviewScopeFp(repo)}>>"`, repo)]],
  review_security: [["MARK_STEP", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_MARK_STEP_review_security_complete>>"', repo)],
    ["next-step --advance", (sid, repo) => F.advance(sid, "review_security", repo)]],
  review_docs: [["MARK_STEP", (sid, repo) => F.mark(sid, 'echo "<<WORKFLOW_MARK_STEP_review_docs_complete>>"', repo)],
    ["next-step --advance", (sid, repo) => F.advance(sid, "review_docs", repo)]],
};

function routes() {
  for (const step of F.GLOSSARY_STEPS) {
    for (const [name, run] of ROUTES[step]) {
      let s = F.setupStep(`route-none-${step}`, step, F.TERM);
      const r = run(s.sid, s.repo);
      const text = r.out + r.err;
      F.check(`${step} via ${name} without a record: not complete`, F.statusOf(s.sid, step) !== "complete",
        `status=${F.statusOf(s.sid, step)}`);
      F.check(`${step} via ${name} without a record: names glossary-check-missing and the recovery`,
        text.includes("glossary-check-missing") && text.includes(`check-glossary-drift`) && text.includes(`--step ${step}`), text);

      s = F.setupStep(`route-rec-${step}`, step, F.TERM);
      recordOk(`${step} via ${name}`, F.drift(s.sid, step, s.repo), 0);
      const r2 = run(s.sid, s.repo);
      F.check(`${step} via ${name} with a clean record: complete`, F.statusOf(s.sid, step) === "complete",
        `status=${F.statusOf(s.sid, step)} exit=${r2.code} ${r2.out}${r2.err}`);
    }
  }
}

module.exports = { matrix, routes };
