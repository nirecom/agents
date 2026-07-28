"use strict";
// Read-only reconciled effective-state snapshot (#1148 / #1133 / #1305 / #1681).
//
// Callers (bin/workflow/next-step, workflow-gate, session-start) need a single
// view that answers "what is the status of every step, once wf-meta auto-skips,
// speculative-skip verdicts, and on-disk completion evidence are taken into
// account?" — computed BEFORE the inconsistency scan runs, so the scan cannot
// false-abort on a step that evidence already resolves (#1148).
//
// This module NEVER writes state (Approach B: read-time derivation). State files
// remain pure records; every consumer derives its effective view here. The caller
// persists snapshot.resolutions via markStep only after the scan has passed, and
// ONLY for evidence resolutions — the veto-driven stages never produce a
// resolution entry, by design.
//
// ORDERING (do not reorder):
//   1. effectiveStatus(step, raw, isWfMeta) is applied FIRST, as an input gate.
//      A step whose effective status is `skipped` (e.g. `detail` under wf-meta)
//      is excluded from evidence resolution entirely — otherwise a wf-meta skip
//      could still be resolved to `complete` by evidence and bypass the approval
//      invariant at persistence time. It is an input gate, never a post-hoc
//      display transform.
//   2. Veto de-skip: an approval-gated step recorded `skipped` whose skip_verdict
//      is `veto` becomes effective-pending (#1681). Without this the veto could
//      never un-skip the step, because nothing ever rewrites the record.
//   3. Post-veto reset: every step after the first vetoed one becomes
//      effective-pending regardless of its record — the work downstream of a
//      vetoed plan stage was performed on a rejected premise.
//   4. Evidence (+ approval, for gated steps) resolution happens LAST, and is
//      skipped entirely for steps touched by stages 2-3.
//
// By default resolution stops at the first step that remains neither complete nor
// skipped — that step is the current step, and steps after it keep their recorded
// status, so a later step's evidence can never manufacture an inconsistency the
// scan would then abort on. opts.resolveAll lifts that cutoff for callers that
// need a complete picture (--list rendering, commit gate, session-start display).

const { VALID_STEPS, readRawState } = require("./state-io");
const { hasCompletionEvidence, hasPlanArtifact } = require("./evidence-resolver");
const { readSkipVerdict } = require("./skip-verdict");
const { hasStagedTestChanges } = require("../../workflow-gate/staged-evidence");
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
//
// opts.evidencePolicy === "staged-only" narrows write_tests to the staged-tests
// predicate alone (the commit gate's historical inline override): the post-merge
// committed-tests fallback must not satisfy a commit-time gate.
function canResolveFromEvidence(step, state, sessionId, opts) {
  let evidenced;
  if (step === "write_tests" && opts && opts.evidencePolicy === "staged-only") {
    const repoDir = (opts && opts.repoDir) || process.env.CLAUDE_PROJECT_DIR || null;
    evidenced = repoDir ? hasStagedTestChanges(repoDir) : false;
  } else {
    evidenced = hasCompletionEvidence(step, sessionId, opts);
  }
  if (!evidenced) return false;
  if (!isApprovalGatedStep(step)) return true;
  const verdict = evaluateCompletionApproval(sessionId, step, state);
  return verdict.approved === true;
}

// Was `step` actually written to disk as complete, with a real timestamp?
//
// readState() synthesizes several steps (clarify_intent among them) as complete
// even when the record was never written, so a migrated/synthesized entry is
// indistinguishable from a genuine one through the normal read path. Reading the
// raw JSON sees through that: an absent key means synthesized, and a null
// updated_at is the synthesis marker.
function hasGenuineRecordedComplete(state, step) {
  try {
    const raw = readRawState(state && state.session_id);
    if (!raw) return false;
    const entry = raw.steps && raw.steps[step];
    if (!entry) return false;
    if (entry.status !== "complete") return false;
    if (typeof entry.updated_at !== "string" || !entry.updated_at) return false;
    return true;
  } catch (_) {
    return false;
  }
}

// evaluateInheritance(state) → { eligible: boolean, scan: "stop" | "continue" | null }
//
// SSOT for "may a new session inherit this state?" (#1305). `scan` tells the
// caller how to continue the transcript walk when the candidate is rejected:
//   "stop"     — a staleness boundary; abort the ENTIRE search (older states are
//                by definition even more stale). Returning only "reject" here was
//                the #1305 bug: the walk fell through to an older transcript.
//   "continue" — this candidate is unusable but carries no boundary meaning.
//
// Fail-open: any unexpected error yields eligible (inheritance is a convenience,
// never a safety gate).
function evaluateInheritance(state) {
  try {
    const steps = (state && state.steps) || {};

    // S0: nothing has happened yet — not stale, just empty.
    const allPending = Object.values(steps).every((s) => !s || s.status === "pending");
    if (allPending) return { eligible: false, scan: "continue" };

    // S1: the session was finalized by the user.
    if (steps.user_verification && steps.user_verification.status === "complete") {
      return { eligible: false, scan: "stop" };
    }

    // S2: implementation reached the security review — #1305 staleness boundary.
    if (steps.review_security && steps.review_security.status === "complete") {
      return { eligible: false, scan: "stop" };
    }

    // S3: clarify_intent genuinely recorded complete but its intent.md is gone —
    // the state no longer describes a reachable session (#1681 symptom 2).
    // Applied to clarify_intent ONLY: outline/detail may legitimately carry a
    // recorded complete with no artifact (plan-stage migration).
    if (
      hasGenuineRecordedComplete(state, "clarify_intent") &&
      !hasPlanArtifact("clarify_intent", state && state.session_id)
    ) {
      return { eligible: false, scan: "stop" };
    }

    return { eligible: true, scan: null };
  } catch (_) {
    return { eligible: true, scan: null };
  }
}

// reconcileEffectiveState(state, sessionId, opts)
//   opts.isWfMeta       : caller-resolved (state.workflow_type === "wf-meta")
//   opts.repoDir        : git root, forwarded to the evidence predicates
//   opts.resolveAll     : resolve evidence for every step instead of stopping at
//                         the current step (default false)
//   opts.evidencePolicy : "default" | "staged-only" (see canResolveFromEvidence)
// → { steps: { <step>: { status, resolved_from, [skip_verdict_state] } },
//     resolutions: [{ step, source }] }
function reconcileEffectiveState(state, sessionId, opts = {}) {
  const isWfMeta = !!(opts && opts.isWfMeta);
  const resolveAll = !!(opts && opts.resolveAll);
  const steps = {};
  const resolutions = [];
  let reachedCurrent = false;
  let vetoIndex = -1;

  for (let i = 0; i < VALID_STEPS.length; i++) {
    const step = VALID_STEPS[i];
    const entry = (state && state.steps && state.steps[step]) || null;
    const raw = (entry && entry.status) || "pending";

    // 1. input gate
    let status = effectiveStatus(step, raw, isWfMeta);
    let resolvedFrom = status === raw ? "state" : "wf-meta-auto-skip";
    let derived = false;

    // The skip verdict is surfaced for every gated step so callers never have to
    // re-read it (next-step's speculative-skip gate reads it straight off here).
    let skipVerdictState = null;
    if (isApprovalGatedStep(step)) {
      try {
        const sv = readSkipVerdict(sessionId, step);
        skipVerdictState = (sv && sv.verdict) || null;
      } catch (_) { skipVerdictState = null; }
    }

    // 2. veto de-skip (#1681) — never recorded as a resolution: Approach B does
    //    not write derived state back.
    if (vetoIndex === -1 && raw === "skipped" && skipVerdictState === "veto") {
      status = "pending";
      resolvedFrom = "skip-verdict-veto";
      derived = true;
      vetoIndex = i;
    } else if (vetoIndex !== -1 && i > vetoIndex) {
      // 3. post-veto reset — everything downstream of a vetoed plan stage was
      //    produced on a rejected premise, whatever its record says.
      status = "pending";
      resolvedFrom = "post-veto-reset";
      derived = true;
    }

    // 4. evidence (+ approval) resolution — skipped for derived steps.
    if (
      !derived &&
      (resolveAll || !reachedCurrent) &&
      status === "pending" &&
      EVIDENCE_STEPS.indexOf(step) !== -1
    ) {
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
    if (isApprovalGatedStep(step)) {
      steps[step].skip_verdict_state = skipVerdictState;
    }
  }

  return { steps, resolutions };
}

module.exports = {
  EVIDENCE_STEPS,
  WF_META_AUTO_SKIP,
  APPROVAL_GATED_STEPS,
  effectiveStatus,
  reconcileEffectiveState,
  evaluateInheritance,
};
