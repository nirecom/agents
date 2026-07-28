"use strict";
// Read-only reconciled effective-state snapshot (#1148 / #1133).
//
// Callers (bin/workflow/next-step) need a single view that answers "what is the
// status of every step, once wf-meta auto-skips and on-disk completion evidence
// are taken into account?" — computed BEFORE the inconsistency scan runs, so the
// scan cannot false-abort on a step that evidence already resolves (#1148).
//
// This module NEVER writes state. The caller persists snapshot.resolutions via
// markStep only after the scan has passed.
//
// ORDERING (do not reorder):
//   1. effectiveStatus(step, raw, isWfMeta) is applied FIRST, as an input gate.
//      A step whose effective status is `skipped` (e.g. `detail` under wf-meta)
//      is excluded from evidence resolution entirely — otherwise a wf-meta skip
//      could still be resolved to `complete` by evidence and bypass the approval
//      invariant at persistence time. It is an input gate, never a post-hoc
//      display transform.
//   2. Evidence (+ approval, for gated steps) resolution happens SECOND.
//
// Resolution stops at the first step that remains neither complete nor skipped —
// that step is the current step. Steps after it keep their recorded status, so a
// later step's evidence can never manufacture an inconsistency the scan would
// then abort on.

const { VALID_STEPS } = require("./state-io");
const { hasCompletionEvidence } = require("./evidence-resolver");
const {
  APPROVAL_GATED_STEPS,
  isApprovalGatedStep,
  evaluateCompletionApproval,
} = require("./completion-approval");

// Steps that carry an on-disk completion-evidence predicate (SSOT: shared with
// bin/workflow/reconcile-state).
const EVIDENCE_STEPS = Object.freeze([
  "clarify_intent", "outline", "detail", "write_tests", "docs",
]);

// Steps auto-skipped in a wf-meta (planning-only) workflow.
const WF_META_AUTO_SKIP = new Set([
  "branching_complete", "detail", "write_tests", "review_tests", "run_tests",
  "review_security", "docs", "user_verification", "cleanup",
]);

function effectiveStatus(step, raw, isWfMeta) {
  if (isWfMeta && WF_META_AUTO_SKIP.has(step) && raw === "pending") return "skipped";
  return raw;
}

// Can this pending step be resolved to complete from on-disk state alone?
// Gated steps additionally require the authoritative approval verdict — the same
// predicate the writeState boundary applies, so the snapshot and the write can
// never disagree.
function canResolveFromEvidence(step, state, sessionId, opts) {
  if (!hasCompletionEvidence(step, sessionId, opts)) return false;
  if (!isApprovalGatedStep(step)) return true;
  const verdict = evaluateCompletionApproval(sessionId, step, state);
  return verdict.approved === true;
}

// reconcileEffectiveState(state, sessionId, opts)
//   opts.isWfMeta : caller-resolved (state.workflow_type === "wf-meta")
//   opts.repoDir  : git root, forwarded to the evidence predicates
// → { steps: { <step>: { status, resolved_from } }, resolutions: [{ step, source }] }
function reconcileEffectiveState(state, sessionId, opts = {}) {
  const isWfMeta = !!(opts && opts.isWfMeta);
  const steps = {};
  const resolutions = [];
  let reachedCurrent = false;

  for (const step of VALID_STEPS) {
    const entry = (state && state.steps && state.steps[step]) || null;
    const raw = (entry && entry.status) || "pending";

    // 1. input gate
    let status = effectiveStatus(step, raw, isWfMeta);
    let resolvedFrom = status === raw ? "state" : "wf-meta-auto-skip";

    // 2. evidence (+ approval) resolution
    if (!reachedCurrent && status === "pending" && EVIDENCE_STEPS.indexOf(step) !== -1) {
      let resolvable = false;
      try {
        resolvable = canResolveFromEvidence(step, state, sessionId, opts);
      } catch (_) { resolvable = false; /* fail-open: stays pending */ }
      if (resolvable) {
        status = "complete";
        resolvedFrom = "evidence";
        resolutions.push({ step, source: "evidence" });
      }
    }

    if (!reachedCurrent && status !== "complete" && status !== "skipped") {
      reachedCurrent = true;
    }
    steps[step] = { status, resolved_from: resolvedFrom };
  }

  return { steps, resolutions };
}

module.exports = {
  EVIDENCE_STEPS,
  WF_META_AUTO_SKIP,
  APPROVAL_GATED_STEPS,
  effectiveStatus,
  reconcileEffectiveState,
};
