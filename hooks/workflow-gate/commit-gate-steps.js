"use strict";
// Commit-gate step scan (#2527 3-4), extracted from workflow-gate.js. The step
// table's commitGate column decides each step: "exempt" is not checked,
// "deferred-in-worktree" is deferred only inside a worktree context, and
// "required" must read settled in the commit snapshot (SSOT: step-table.js).

const { VALID_STEPS } = require("../workflow-state");
const { commitGateOf } = require("../workflow-state/step-table");
const { hasStagedTestChanges } = require("./staged-evidence");
const { isWorktreeContext } = require("./worktree-context");
const { checkGlossaryRecord, GATED_STEPS: GLOSSARY_GATED_STEPS } = require("./glossary-record-checker");

// write_tests counts as bypassed when staged tests/ evidence resolved it, or when
// a BUGFIX session skipped it outside the skippable set yet staged tests (#833, #1147).
function isWriteTestsEvidenceBypassed(commitSnapshot, skippable, repoDir) {
  const snapshotWt = commitSnapshot && commitSnapshot.steps && commitSnapshot.steps.write_tests;
  if (snapshotWt && snapshotWt.resolved_from === "evidence") return true;
  return !!(
    snapshotWt && snapshotWt.status === "skipped" &&
    !skippable.includes("write_tests") &&
    hasStagedTestChanges(repoDir)
  );
}

// → { incomplete: string[], incompleteReasons: { [step]: string } }
function collectIncompleteSteps({ state, commitSnapshot, sessionId, repoDir, docsOnly, isWip, skippable }) {
  const incomplete = [];
  const incompleteReasons = {};
  const writeTestsEvidenceBypassed = isWriteTestsEvidenceBypassed(commitSnapshot, skippable, repoDir);
  let inWorktree = null;
  const worktree = () => (inWorktree === null ? (inWorktree = isWorktreeContext(repoDir)) : inWorktree);

  for (const step of VALID_STEPS) {
    const gate = commitGateOf(step);
    if (gate === "exempt") continue;
    const stepState = state.steps && state.steps[step];
    const snap = commitSnapshot && commitSnapshot.steps && commitSnapshot.steps[step];
    const status = snap ? snap.status : (stepState ? stepState.status : "pending");

    // #2529: the glossary_check record is re-judged against the current staged set at every
    // status, before any step checker, bypass, or status short-circuit can let the step through.
    // A stage with none of its targets staged passes (evaluateGlossaryCheck, commit mode).
    if (GLOSSARY_GATED_STEPS.includes(step)) {
      const g = checkGlossaryRecord(step, { state, sessionId, repoDir });
      if (g.action === "block") {
        incompleteReasons[step] = g.reason;
        incomplete.push(step);
        continue;
      }
    }

    if (step === "review_tests") {
      const { checkReviewTests } = require("./review-tests-checker");
      const rt = checkReviewTests(step, stepState, { docsOnly, writeTestsEvidenceBypassed, repoDir, sessionId });
      if (rt.action === "skip") continue;
      if (rt.action === "block") {
        if (rt.reason) incompleteReasons[step] = rt.reason;
        incomplete.push(step);
        continue;
      }
    }

    // review_docs runs BEFORE the docs-only short-circuit: a docs-only commit must
    // still satisfy it, re-checked against staged blobs every commit (TOCTOU-safe).
    if (step === "review_docs") {
      const { checkReviewDocs } = require("./review-docs-checker");
      const rd = checkReviewDocs(step, stepState, { repoDir, sessionId });
      if (rd.action === "skip") continue;
      if (rd.action === "block") {
        if (rd.reason) incompleteReasons[step] = rd.reason;
        incomplete.push(step);
        continue;
      }
    }

    if (status === "complete") continue;
    // H1 (TOCTOU): a run_tests skip is honored only while the CURRENT staged set is docs-only.
    if (status === "skipped" && skippable.includes(step) && (step !== "run_tests" || docsOnly)) continue;
    if (step === "write_tests" && writeTestsEvidenceBypassed) continue;
    if (docsOnly && step !== "user_verification") continue;
    // Worktree commits are intermediate: these steps are judged at the merge / worktree-end boundary.
    if (gate === "deferred-in-worktree" && worktree()) continue;
    if (step === "user_verification" && isWip) continue;
    incomplete.push(step);
  }
  return { incomplete, incompleteReasons };
}

module.exports = { collectIncompleteSteps, isWriteTestsEvidenceBypassed };
