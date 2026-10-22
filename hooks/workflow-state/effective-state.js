"use strict";
// Read-only reconciled effective-state snapshot (#1148/#1133/#1305/#1681).
// Answers "status of every step once step-table skips, speculative-skip
// verdicts, and on-disk evidence are applied" — computed BEFORE the
// inconsistency scan so it cannot false-abort (#1148). NEVER writes state
// (Approach B: read-time derivation); the caller persists only evidence
// resolutions, and only after the scan passes. ORDERING (do not reorder):
// 1 effectiveStatus input-gate → 2 veto de-skip → 3 post-veto reset / unapproved-complete / glossary-check refusal →
// 3b delivery boundary (navigate only) → 4 evidence(+approval) resolution → 5 write_code resume mask (second pass,
// overrides 4). Detail: effective-state/write-code-resume.js and the #1681/
// #1665 suites. Resolution stops at the first unsettled step unless opts.resolveAll.

const { VALID_STEPS, normalizeStateVersion, isGenuineProvenance } = require("./state-io");
const { hasCompletionEvidence, hasPlanArtifact } = require("./evidence-resolver");
const { readSkipVerdict } = require("./skip-verdict");
const { applyWriteCodeResume } = require("./effective-state/write-code-resume");
const { navigateBoundaryStatus } = require("./effective-state/delivery-boundary");
const { isStepRequired, canonicalStepName } = require("./step-table");
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
// Release steps whose evidence is a forge / remote-ref query (#2527 3-3). Kept
// apart from EVIDENCE_STEPS, which reconcile-state walks offline.
// user_verification (#2527 4-4) answers only on the web-merge channel (an observed web merge).
const NETWORK_EVIDENCE_STEPS = Object.freeze(["push_branch", "user_verification", "merge_to_main"]);

// Table-skip (#2527): a pending step the session profile does not owe reads as
// skipped. Which steps are owed is the step table (SSOT: ./step-table.js); the
// profile comes from ./session-profile.js, resolved once per entrypoint.
function effectiveStatus(step, raw, profile) {
  if (raw === "pending" && !isStepRequired(profile || null, step)) return "skipped";
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
    // state rides along so the docs predicate reads write_code_scope_manifest off it (#2327).
    evidenced = hasCompletionEvidence(step, sessionId, Object.assign({}, opts, { state }));
  }
  if (!evidenced) return false;
  if (!isApprovalGatedStep(step)) return true;
  const verdict = evaluateCompletionApproval(sessionId, step, state);
  if (verdict.approved !== true) return false;
  // #2529: the same glossary-check predicate the appendEvents boundary applies (lazy: avoids a cycle).
  const { evaluateGlossaryCheck } = require("./glossary-check/record");
  return evaluateGlossaryCheck(sessionId, step, state, { repoDir: opts && opts.repoDir }).ok === true;
}

// isUnapprovedGatedComplete(step, raw, state, sessionId) → true when a gated step is recorded
// complete but its approval no longer verifies (#2277 S13). Read-time only: the record and its
// downstream steps stay as written, so a re-approval resumes from the recorded position.
function isUnapprovedGatedComplete(step, raw, state, sessionId) {
  if (raw !== "complete" || !isApprovalGatedStep(step)) return false;
  try {
    const sid = sessionId || (state && state.session_id) || null;
    return evaluateCompletionApproval(sid, step, state).approved !== true;
  } catch (_) {
    return false;
  }
}

// glossaryRefusalOfGatedComplete(step, raw, state, sessionId, opts) → the glossary-check refusal
// code (stale / findings-unresolved / fingerprint-unavailable) of a plan stage recorded complete
// with a glossary_check record, else null (#2529). Read-time only, like the approval re-check
// above. A returned unreadable-inputs verdict is a refusal; only a thrown error is fail-open.
function glossaryRefusalOfGatedComplete(step, raw, state, sessionId, opts) {
  if (raw !== "complete" || !isApprovalGatedStep(step)) return null;
  try {
    const sid = sessionId || (state && state.session_id) || null;
    const { glossaryRefusalOfComplete } = require("./glossary-check/record");
    return glossaryRefusalOfComplete(sid, step, state, { repoDir: opts && opts.repoDir }) || null;
  } catch (_) {
    return null;
  }
}

// gatedCompleteRefusal(step, raw, state, sessionId, opts) → why a gated step recorded complete
// does not read as complete ("unapproved-complete" or a glossary-check code), else null. The one
// predicate every reader that picks the current step or answers "already complete" shares (#2529).
function gatedCompleteRefusal(step, raw, state, sessionId, opts) {
  if (isUnapprovedGatedComplete(step, raw, state, sessionId)) return "unapproved-complete";
  return glossaryRefusalOfGatedComplete(step, raw, state, sessionId, opts);
}

// recordedEventsOf(state) → the events actually recorded for this state, or
// null when none can be read. Shared by every predicate answering about what
// was RECORDED, not what the projection derived (CPR-SSOT). The stream is read
// off the state object the caller holds, never re-read by state.session_id — a
// migrated fixture or transcript-recovered donor has a file name that is the
// canonical id but a different in-memory stream. Related: hasGenuineRecorded
// Complete (below) treats only the latest step_status=complete with a non-
// backfilled provenance as genuine (observed/declared stay genuine), a RECORDED
// fact scanned from the stream since #1733 — the folded projection exposes only
// final status, never provenance.
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
      if (e.kind !== "step_status" || canonicalStepName(e.step) !== step) continue;
      latest = e;
    }
    if (!latest) return false;
    if (latest.status !== "complete") return false;
    return isGenuineProvenance(latest.provenance);
  } catch (_) {
    return false;
  }
}

// evaluateResumability(state) → { eligible, reason }. SSOT for "is this state
// usable by a session that continues it?" (#1305). Pre-#1305 it also returned
// scan:"stop"/"continue" to steer a directory walk for donor selection; that is
// now keyed on lineage (hooks/workflow-state/inheritance.js) with the nearest
// state-holding ancestor as sole decider, so the field is gone. S2
// (review_security complete) was likewise REMOVED: it guarded against an
// unrelated session grabbing late-stage work, but with descent proven the heir
// IS this session's continuation. Fail-open: any unexpected error yields
// eligible (inheritance is a convenience, never a safety gate).
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

    // S1: the session's change was delivered (#2527: approval alone no longer
    // finishes a session — merge_to_main is the step after it).
    if (steps.merge_to_main && steps.merge_to_main.status === "complete") {
      return { eligible: false, reason: "delivered" };
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
//   opts.profile        : caller-resolved session profile (resolveSessionProfile);
//                         absent → every step is owed (no table-skip)
//   opts.repoDir        : git root, forwarded to the evidence predicates
//   opts.resolveAll     : resolve evidence for every step, not just to the current
//   opts.evidencePolicy : "default" | "staged-only" | { network: true } (release steps)
//   opts.deliveryBoundary: "navigate" enables stage 3b (navigation callers only)
// → { steps: { <step>: { status, resolved_from, [skip_verdict_state] } }, resolutions: [{ step, source }] }
function reconcileEffectiveState(state, sessionId, opts = {}) {
  const profile = (opts && opts.profile) || null;
  const resolveAll = !!(opts && opts.resolveAll);
  const navigate = !!(opts && opts.deliveryBoundary === "navigate");
  const network = !!(opts && opts.evidencePolicy && opts.evidencePolicy.network === true);
  const steps = {};
  const resolutions = [];
  let reachedCurrent = false;
  let vetoIndex = -1;

  for (let i = 0; i < VALID_STEPS.length; i++) {
    const step = VALID_STEPS[i];
    const entry = (state && state.steps && state.steps[step]) || null;
    const raw = (entry && entry.status) || "pending";

    // 1. input gate
    let status = effectiveStatus(step, raw, profile);
    let resolvedFrom = status === raw ? "state" : "table-skip";
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
    } else if (status === "complete") {
      const refusal = gatedCompleteRefusal(step, raw, state, sessionId, opts);
      if (refusal) {
        status = "pending";
        resolvedFrom = refusal;
        derived = true;
      }
    }

    // 3b. delivery boundary — navigation callers only (./effective-state/delivery-boundary.js).
    if (!derived && navigate) {
      const settledTo = navigateBoundaryStatus(step, status, state, profile);
      if (settledTo) {
        status = settledTo;
        resolvedFrom = "delivery-boundary";
        derived = true;
      }
    }

    // 4. evidence (+ approval) resolution — skipped for derived steps. The
    //    release steps query the forge, so only the evaluated step of a
    //    network-enabled caller reaches them (never resolveAll / hooks).
    const offlineEvidence = (resolveAll || !reachedCurrent) && EVIDENCE_STEPS.indexOf(step) !== -1;
    const networkEvidence = network && !reachedCurrent && NETWORK_EVIDENCE_STEPS.indexOf(step) !== -1;
    if (!derived && status === "pending" && (offlineEvidence || networkEvidence)) {
      let resolvable = false;
      try {
        resolvable = canResolveFromEvidence(step, state, sessionId, opts);
      } catch (_) { resolvable = false; /* fail-open: stays pending */ }
      if (resolvable && step === "user_verification") {
        // A web merge is observed, never recorded: settleMergeToMain owns the uv record.
        status = "complete";
        resolvedFrom = "web-merge-evidence";
      } else if (resolvable) {
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

  // 5. write_code resume mask — last, so it can override stage 4.
  applyWriteCodeResume(steps, resolutions, state);

  return { steps, resolutions };
}

module.exports = {
  EVIDENCE_STEPS,
  NETWORK_EVIDENCE_STEPS,
  APPROVAL_GATED_STEPS,
  effectiveStatus,
  isUnapprovedGatedComplete,
  gatedCompleteRefusal,
  reconcileEffectiveState,
  evaluateResumability,
  evaluateInheritance,
};
