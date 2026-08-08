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

const { VALID_STEPS, normalizeStateVersion } = require("./state-io");
const { hasCompletionEvidence, hasPlanArtifact } = require("./evidence-resolver");
const { readSkipVerdict } = require("./skip-verdict");
const { hasStagedTestChanges } = require("../workflow-gate/staged-evidence");
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
//
// `final_report` is deliberately NOT a member: it is a TERMINAL step for wf-code
// and wf-meta alike (SSOT: state-io TERMINAL_STEPS), and auto-skipping it would
// silently erase the boundary the interval calculation folds against.
// `pre_final_report_gate` is likewise excluded — a meta session still closes.
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

// Was `step` genuinely completed by a process that saw it happen — as opposed to
// reconstructed by a migration or synthesized by session inheritance?
//
// Since #1733 this is a RECORDED FACT, not a heuristic: the latest `step_status`
// event for the step must say `complete`, and its `provenance` must not be
// `backfilled`. `observed` (a live markStep) and `declared` (a RESET_FROM force
// -complete) both stay genuine, preserving the pre-#1733 verdict.
//
// The stream is scanned rather than the folded projection on purpose: the
// projection exposes only the FINAL status, never the provenance of the event
// that produced it. The stream is taken off the state object the caller already
// holds — re-reading it by `state.session_id` would answer about a DIFFERENT
// session whenever the two disagree, which is exactly the case for a migrated
// fixture or a transcript-recovered donor whose file name is the canonical id.
// The events actually recorded for this state, or null when none can be read.
// Shared by every predicate that must answer about what was RECORDED rather
// than about what the projection derived (CPR-SSOT).
function recordedEventsOf(state) {
  if (!state || typeof state !== "object") return null;
  if (Array.isArray(state.events)) return state.events;
  // A raw v1 object handed in directly: fold it to events in memory only.
  const normalized = normalizeStateVersion(state);
  return normalized && Array.isArray(normalized.events) ? normalized.events : null;
}

// True when the stream records at least one step leaving `pending`.
function hasRecordedProgress(state) {
  try {
    const events = recordedEventsOf(state);
    if (!events) {
      // No stream to judge by — fall back to the projection rather than
      // declaring a state we cannot read to be empty.
      const steps = (state && state.steps) || {};
      return Object.values(steps).some((s) => s && s.status && s.status !== "pending");
    }
    return events.some(
      (e) => e && e.kind === "step_status" && e.status && e.status !== "pending"
    );
  } catch (_) {
    return true; // fail-open: inheritance is a convenience, never a safety gate
  }
}

function hasGenuineRecordedComplete(state, step) {
  try {
    const events = recordedEventsOf(state);
    if (!events) return false;
    let latest = null;
    for (const e of events) {
      if (!e || typeof e !== "object") continue;
      if (e.kind !== "step_status" || e.step !== step) continue;
      latest = e;
    }
    if (!latest) return false;
    if (latest.status !== "complete") return false;
    return latest.provenance !== "backfilled";
  } catch (_) {
    return false;
  }
}

// evaluateResumability(state) → { eligible: boolean, reason: string|null }
//
// SSOT for "is this state usable by a session that continues it?" (#1305).
//
// WHY the shape changed: pre-#1305 this also returned scan:"stop"/"continue",
// because the donor was picked by scanning a whole directory of transcripts and
// the verdict had to steer that walk. Donor selection is now keyed on lineage
// (hooks/workflow-state/inheritance.js), and the nearest ancestor that holds
// state is the SOLE decision-maker — there is no walk left to steer, so the
// field is gone.
//
// S2 (review_security complete) was REMOVED for the same reason: it existed as a
// staleness boundary against an UNRELATED session grabbing late-stage work.
// With descent proven, the heir IS that session's continuation, and refusing to
// let it resume its own verified work protects nobody.
//
// Fail-open: any unexpected error yields eligible (inheritance is a convenience,
// never a safety gate).
function evaluateResumability(state) {
  try {
    const steps = (state && state.steps) || {};

    // S0: nothing has happened yet — there is nothing to carry over.
    //
    // Judged on the RECORDED stream, not on `state.steps`: readState() runs
    // applyLegacyV1ReadDefaults, which synthesizes workflow_init /
    // clarify_intent / branching_complete as complete for every v1 file. A
    // genuinely empty v1 donor therefore never looks all-pending in the
    // projection, and would be offered as an inheritance source that carries
    // nothing but those three synthetic completions.
    if (!hasRecordedProgress(state)) return { eligible: false, reason: "all-pending" };

    // S1: the session was finalized by the user.
    if (steps.user_verification && steps.user_verification.status === "complete") {
      return { eligible: false, reason: "user-verified" };
    }

    // S3: clarify_intent genuinely recorded complete but its intent.md is gone —
    // the state no longer describes a reachable session (#1681 symptom 2).
    // Applied to clarify_intent ONLY: outline/detail may legitimately carry a
    // recorded complete with no artifact (plan-stage migration).
    if (
      hasGenuineRecordedComplete(state, "clarify_intent") &&
      !hasPlanArtifact("clarify_intent", state && state.session_id)
    ) {
      return { eligible: false, reason: "intent-artifact-missing" };
    }

    return { eligible: true, reason: null };
  } catch (_) {
    return { eligible: true, reason: null };
  }
}

// Back-compat shim for the pre-#1305 name and shape.
//
// `scan` steered the directory walk that used to pick a donor; nothing walks
// anymore, so the field is derived rather than decided — "stop" is simply the
// restatement of "not eligible". Kept because the #1733 event-stream suite
// observes hasGenuineRecordedComplete (module-private, deliberately) through
// this exact signature. New code must call evaluateResumability.
function evaluateInheritance(state) {
  const verdict = evaluateResumability(state);
  return Object.assign({}, verdict, { scan: verdict.eligible ? null : "stop" });
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
  evaluateResumability,
  evaluateInheritance,
};
