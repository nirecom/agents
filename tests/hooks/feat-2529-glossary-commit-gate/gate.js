"use strict";
// The commit gate's step scan driven in-process: collectIncompleteSteps with the session's
// projected state and the fixture index, exactly as workflow-gate.js calls it. A glossary
// verdict for a step is read from incompleteReasons[step]; pass means no glossary-* code there.

const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");

function skippableOf(sid) {
  const ws = require(path.join(F.ROOT, "hooks/workflow-state"));
  const fn = ws.getSkippableSteps || require(path.join(F.ROOT, "hooks/workflow-state/state-io")).getSkippableSteps;
  return fn(sid);
}

// opts: docsOnly, commitSnapshot. → { incomplete, incompleteReasons } | { threw }
function scan(sid, repo, opts) {
  const o = opts || {};
  const { collectIncompleteSteps } = require(path.join(F.ROOT, "hooks/workflow-gate/commit-gate-steps.js"));
  try {
    return collectIncompleteSteps({
      state: F.readState(sid), commitSnapshot: o.commitSnapshot || null, sessionId: sid, repoDir: repo,
      docsOnly: !!o.docsOnly, isWip: false, skippable: skippableOf(sid),
    });
  } catch (e) {
    return { threw: String((e && e.stack) || e), incomplete: [], incompleteReasons: {} };
  }
}

const reasonOf = (r, step) => String((r.incompleteReasons || {})[step] || "");

function blocks(label, r, step, code, stage) {
  const reason = reasonOf(r, step);
  F.check(`${label}: ${step} blocked with ${code}`, (r.incomplete || []).includes(step) && reason.includes(code),
    r.threw || JSON.stringify(r.incompleteReasons));
  if (stage) {
    F.check(`${label}: incompleteReasons.${step} names the recovery`,
      reason.includes(`check-glossary-drift --stage ${stage} --record`), reason);
  }
  return reason;
}

function passes(label, r, step) {
  return F.check(`${label}: ${step} has no glossary block`, !r.threw && !F.GLOSSARY_CODES.test(reasonOf(r, step)),
    r.threw || reasonOf(r, step));
}

// Exit 1 alone is also what a missing CLI returns, so an unresolved run must print its DRIFT line.
function recordOk(label, r, want) {
  const text = r.out + r.err;
  const ok = r.code === want && (want !== 1 || /DRIFT: \S+ "/.test(text));
  return F.check(`${label}: check-glossary-drift --record exits ${want}`, ok, `exit=${r.code} ${text}`);
}

// review_tests' own checker passes only with a current review_scope_manifest; recording it
// isolates the glossary verdict from the review-scope verdict.
function recordReviewScope(sid, repo) {
  const ev = require(path.join(F.ROOT, "hooks/workflow-gate/review-tests-evidence.js"));
  const m = ev.computeReviewScopeManifest(repo);
  F.appendRaw(sid, [F.annotationEvent("review_tests", "review_scope_manifest", { v: 1, files: m.ok ? m.files : {} })]);
}

// The stage's step settled `complete` (raw) with a fresh --record of the staged target.
function completedStage(tag, stage, opts) {
  const s = F.setupStage(tag, stage, F.TERM, Object.assign({ ownStatus: "complete" }, opts || {}));
  if (stage === "tests") recordReviewScope(s.sid, s.repo);
  return s;
}

const NOT_NEEDED = {
  review_security: 'echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: fixture skip>>"',
  review_tests: 'echo "<<WORKFLOW_REVIEW_TESTS_NOT_NEEDED: fixture skip>>"',
  review_docs: 'echo "<<WORKFLOW_REVIEW_DOCS_NOT_NEEDED: fixture skip>>"',
};

// Skips `step` through its NOT_NEEDED sentinel; a raw skipped event backs it up when the
// route refuses in this fixture, so the case always starts from status=skipped.
function skipStep(sid, step, repo) {
  F.mark(sid, NOT_NEEDED[step], repo);
  if (F.statusOf(sid, step) !== "skipped") F.appendRaw(sid, [F.stepStatusEvent(step, "skipped")]);
  return F.statusOf(sid, step) === "skipped";
}

module.exports = { scan, blocks, passes, recordOk, recordReviewScope, completedStage, skipStep, reasonOf };
