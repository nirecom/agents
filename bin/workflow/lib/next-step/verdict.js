"use strict";
// Verdict computation for bin/workflow/next-step: emit() plus the whole
// computeVerdict block (including its nested persistResolutions and
// applyRecordedVerdictSkip, which self-recurses into computeVerdict).
//
// SIZE NOTE: this file knowingly exceeds the WARN threshold (300 lines) in
// rules/coding/file-split.md. The HARD limit (500 lines) IS met. A second-stage
// split of this block (diagnostics / recovery layer) is deliberately deferred to
// a follow-up issue so that the #1756 split stays a mechanical code move.

const fs = require("fs");
const {
  VALID_STEPS,
  VALID_STATUSES,
  isSettledStatus,
  readState,
  getStatePath,
  resolveSessionId,
  markStep,
  hasPlanArtifact,
} = require("../../../../hooks/workflow-state");
const {
  effectiveStatus,
  reconcileEffectiveState,
} = require("../../../../hooks/workflow-state/effective-state");
const {
  APPROVAL_GATED_STEPS,
  isApprovalGatedStep,
  UnapprovedCompletionError,
  confirmSentinelFor,
  recoveryFor,
} = require("../../../../hooks/workflow-state/completion-approval");
const { STEP_TO_SKILL, STEP_HINT, isTerminalStep } = require("./steps");
const { resolveRepoDir } = require("./repo-dir");
const { ENTRYPOINT_PATH } = require("./entrypoint-path");

function emit(action, skill, hint, reason, skipHint) {
  let out =
    "ACTION=" + action + "\n" +
    "NEXT_SKILL=" + (skill || "") + "\n" +
    "NEXT_HINT='" + (hint || "") + "'\n" +
    "REASON='" + (reason || "") + "'\n";
  // #485: optional advisory SKIP_HINT line — appended ONLY when non-empty, so the
  // 4-line contract is byte-identical on every other step. Value is a fixed
  // sentinel literal (no quotes/whitespace) → unquoted SKIP_HINT=<value> form.
  if (skipHint) {
    out += "SKIP_HINT=" + skipHint + "\n";
  }
  process.stdout.write(out);
  process.exit(0);
}

// ---- Verdict computation --------------------------------------------------

function computeVerdict(rawSid, _didAutoRepair) {
  const sid = resolveSessionId({ sessionIdFromInput: rawSid });
  if (!sid) {
    emit("blocked", "", "", "session-id-unresolved");
    return;
  }

  // Quiet layer (#1607): when the session is deliberately outside the workflow,
  // next-step reports ACTION=paused instead of nagging with the next step.
  // Cause-specific resume guidance — NEXT_STEP_RESUME does NOT clear workflow-OFF.
  // fail-open: a marker-read failure just means the normal (noisy) verdict.
  try {
    const { isNextStepPaused, isWorkflowOff } = require("../../../../hooks/lib/session-markers");
    if (isNextStepPaused(sid)) {
      emit(
        "paused",
        "",
        "next-step is quiet. Take no workflow action; continue the out-of-workflow work. " +
          "Resume with: echo \"<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>\"",
        "next-step-paused"
      );
      return;
    }
    if (isWorkflowOff(sid)) {
      emit(
        "paused",
        "",
        "workflow enforcement is OFF, so next-step is quiet. Take no workflow action. " +
          "Restore with: echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: {reason}>>\" " +
          "(a next-step resume sentinel does NOT clear workflow-OFF)",
        "workflow-off-quiet"
      );
      return;
    }
  } catch (_e) { /* fail-open */ }

  const statePath = getStatePath(sid);
  if (!fs.existsSync(statePath)) {
    emit("invoke", "workflow-init", "Run /workflow-init to initialize the session state.", "no-state");
    return;
  }

  const state = readState(sid);
  if (!state || typeof state.steps !== "object" || !state.steps) {
    emit("abort", "", "", "corrupt-state: unreadable or non-object JSON");
    return;
  }

  const isWfMeta = (state.workflow_type === "wf-meta");
  const repoDir = resolveRepoDir();

  // Precondition preserved ahead of the snapshot: clarify_intent requires
  // closes_issues. Resolved against the RAW walk so evidence-based resolution of
  // clarify_intent cannot skip past the check (pre-#1148 precedence).
  {
    let rawCurrent = null;
    for (const step of VALID_STEPS) {
      if (isTerminalStep(step)) continue;
      const raw = (state.steps[step] || {}).status || "pending";
      const status = effectiveStatus(step, raw, isWfMeta);
      if (!isSettledStatus(status)) { rawCurrent = step; break; }
    }
    if (rawCurrent === "clarify_intent") {
      const issues = state.closes_issues;
      if (!issues || !Array.isArray(issues) || issues.length === 0) {
        emit("blocked", "", "closes_issues is empty -- run /workflow-init to populate it.", "closes_issues-empty");
        return;
      }
    }
  }

  // #1148: build the read-only reconciled snapshot BEFORE the inconsistency scan,
  // so a step that on-disk evidence already resolves cannot false-abort the scan.
  // Gated steps (outline/detail) resolve here only when the approval invariant
  // is already satisfied (#1133) — the same predicate writeState enforces.
  const snapshot = reconcileEffectiveState(state, sid, { repoDir, isWfMeta });
  const snapStatus = (step) => (snapshot.steps[step] || {}).status;

  // A-4 speculative-skip gate (#1681): an unresolved verdict blocks the whole
  // walk, not just the terminal "workflow-complete" branch — a pending verdict
  // means we do not yet know whether the skipped stage is legitimate, so no
  // downstream step may be advised. The vetoed case is NOT handled here: the
  // snapshot already de-skips a vetoed step to pending, so the ordinary
  // currentStep walk below selects it and routes to its planner skill.
  for (const gatedStep of APPROVAL_GATED_STEPS) {
    if ((snapshot.steps[gatedStep] || {}).skip_verdict_state !== "pending") continue;
    // applyRecordedVerdictSkip marks the step skipped with skip_reason="recorded-verdict:..."
    // THEN writes a pending verdict file, THEN calls computeVerdict recursively. In that
    // recursive call the pending verdict is already on disk, so this gate would fire and
    // return blocked instead of advancing. Discriminate by skip_reason: only speculative
    // skips (written by make-outline-plan/make-detail-plan) block here; recorded-verdict
    // skips have an already-trusted skip judgment and should pass through.
    const rawEntry = (state.steps && state.steps[gatedStep]) || {};
    if (
      rawEntry.status === "skipped" &&
      typeof rawEntry.skip_reason === "string" &&
      rawEntry.skip_reason.startsWith("recorded-verdict:")
    ) {
      continue;
    }
    emit(
      "blocked", "",
      gatedStep + " speculative skip is pending verification by skip-verifier. Re-run next-step after verifier completes.",
      "speculative-skip-pending"
    );
    return;
  }

  // Persist the snapshot's evidence-resolved steps. Called only after the
  // inconsistency scan has passed (or when there is nothing left to scan).
  function persistResolutions() {
    for (const r of snapshot.resolutions) {
      try {
        markStep(sid, r.step, "complete");
      } catch (e) {
        if (e instanceof UnapprovedCompletionError) {
          emit("blocked", "", recoveryFor(r.step), "unapproved-completion: " + r.step);
          return;
        }
        /* fail-open on any other write failure */
      }
    }
  }

  // Walk the snapshot to find currentStep (its statuses are already effective —
  // do NOT re-apply effectiveStatus here).
  let currentIdx = -1;
  let currentStep = null;
  for (let i = 0; i < VALID_STEPS.length; i++) {
    const step = VALID_STEPS[i];
    if (isTerminalStep(step)) continue;
    const status = snapStatus(step);
    if (!isSettledStatus(status)) {
      // post-merge guard: treat user_verification reset by gh pr merge as complete.
      // Mirrors post-compact.js lines 66-70 (same reset_reason predicate).
      if (
        step === "user_verification" &&
        status === "pending" &&
        (state.steps["user_verification"] || {}).reset_reason === "post-merge"
      ) {
        continue;
      }
      currentIdx = i;
      currentStep = step;
      break;
    }
  }

  if (currentStep === null) {
    persistResolutions();
    // Reaching here, a skipped gated step can only carry a `confirm` verdict or
    // none at all: `pending` was blocked by the snapshot gate above, and `veto`
    // was de-skipped to pending inside reconcileEffectiveState (so currentStep
    // would not be null). Both remaining cases are fail-open: re-invoke
    // /write-tests so the skipped stage gets re-confirmed downstream (#1681).
    try {
      for (const gatedStep of APPROVAL_GATED_STEPS) {
        const stepData = state.steps[gatedStep];
        if (!stepData || stepData.status !== "skipped") continue;
        // invoke write-tests only when write_tests is NOT settled. Settled covers
        // BOTH "skipped" (session opted out of tests entirely) and "complete"
        // (tests were written, reviewed and passed) — re-invoking /write-tests
        // after the normal path already completed is wrong and used to produce a
        // permanent false ACTION=invoke at the end of the workflow (#1756).
        const wtsEntry = state.steps["write_tests"];
        if (wtsEntry && isSettledStatus(wtsEntry.status)) continue;
        emit("invoke", STEP_TO_SKILL["write_tests"] || "write-tests", "Run /write-tests via the Skill tool.", "write_tests");
        return;
      }
    } catch (_) { /* fail-open */ }
    emit("done", "", "", "workflow-complete");
    return;
  }

  // Evidence-based auto-complete for write_tests / outline / detail / clarify_intent /
  // docs is now performed once, up front, by reconcileEffectiveState (#1148). The
  // snapshot is already resolved here; persistence happens after the scan passes.

  // A-4: authoritative recorded-verdict skip BEFORE inconsistency scan.
  // A valid skip_judgment allows resolving outline/detail=pending BEFORE the scan
  // fires an abort on "later step complete but current step pending".
  if (currentStep === "outline") {
    const v = applyRecordedVerdictSkip(sid, rawSid, "outline", "recorded-verdict: so_c1+so_c2 met");
    if (v !== null) return v;
  }
  if (currentStep === "detail") {
    const v = applyRecordedVerdictSkip(sid, rawSid, "detail", "recorded-verdict: sd_c1+sd_c2+sd_c3 met");
    if (v !== null) return v;
  }

  // Inconsistency: later step is complete OR invalid status anywhere.
  // Runs AGAINST THE SNAPSHOT (#1148): steps already resolved from evidence read
  // as complete here, so a pending-but-evidenced step can no longer false-abort.
  for (let i = 0; i < VALID_STEPS.length; i++) {
    const step = VALID_STEPS[i];
    // A terminal step recorded complete is the session's own end marker, never
    // evidence that an earlier step was skipped over.
    if (isTerminalStep(step)) continue;
    const stEntry = state.steps[step];
    const rawStatus = stEntry ? stEntry.status : undefined;
    const status = rawStatus !== undefined && rawStatus !== null
      ? snapStatus(step)
      : undefined;
    if (status !== undefined && status !== null && VALID_STATUSES.indexOf(status) === -1) {
      emit("abort", "", "", "inconsistent: " + step + " has unknown status " + rawStatus);
      return;
    }
    if (i > currentIdx && status === "complete") {
      if (step === "run_tests" && currentStep === "write_tests") {
        // Scoped recovery: run_tests auto-completed ahead of write_tests.
        // Point at the --reset tool instead of a full /workflow-init reset.
        // No single quotes — emit() wraps NEXT_HINT/REASON in single quotes.
        emit(
          "abort",
          "",
          "run_tests is complete but write_tests is not. Recovery: node " + ENTRYPOINT_PATH +
            " --reset run_tests (state is session-global; no worktree cd needed). Then re-run /write-tests.",
          "inconsistent: " + step + " is complete but " + currentStep + " is pending"
        );
        return;
      }
      if (step === "detail" && currentStep === "outline") {
        // outline is approval-gated: --mark is refused without a recorded
        // approval, so the recovery is the CONFIRM sentinel, not --mark (#1133).
        emit(
          "abort",
          "",
          "detail is complete but outline is pending (compaction gap). outline requires user approval. " +
            "Recovery: ask the user to approve, then emit: echo \"<<" + confirmSentinelFor("outline") +
            ": {summary}>>\". Then re-run next-step.",
          "inconsistent: " + step + " is complete but " + currentStep + " is pending"
        );
        return;
      }
      if (step === "review_tests" && currentStep === "write_tests") {
        // Scoped recovery: review_tests auto-completed ahead of write_tests.
        // Point at the --reset tool instead of a full /workflow-init reset.
        // No single quotes — emit() wraps NEXT_HINT/REASON in single quotes.
        emit(
          "abort",
          "",
          "review_tests is complete but write_tests is not. Recovery: node " + ENTRYPOINT_PATH +
            " --reset review_tests (state is session-global; no worktree cd needed). Then re-run /write-tests.",
          "inconsistent: " + step + " is complete but " + currentStep + " is pending"
        );
        return;
      }
      const { hasCompletionEvidence: hceGeneric } = require("../../../../hooks/workflow-state/evidence-resolver");
      const hasEvidence = hceGeneric(currentStep, sid, { repoDir });
      let genericHint;
      if (hasEvidence && isApprovalGatedStep(currentStep)) {
        // Gated steps: --mark cannot approve a plan stage (#1133).
        genericHint =
          "Compaction gap: " + step + " is complete but " + currentStep + " is pending. " +
          "Artifact for " + currentStep + " exists but user approval is not on record. " +
          "Recovery: ask the user to approve, then emit: echo \"<<" +
          confirmSentinelFor(currentStep) + ": {summary}>>\".";
      } else if (hasEvidence) {
        genericHint =
          "Compaction gap: " + step + " is complete but " + currentStep + " is pending. " +
          "Artifact for " + currentStep + " exists. Recovery: node " + ENTRYPOINT_PATH +
          " --mark " + currentStep + " complete (session-global; no cd needed).";
      } else {
        genericHint =
          "Stale state from a prior workflow run or cross-task contamination detected. " +
          "Re-run /workflow-init to reset (it clears downstream steps automatically).";
      }
      emit(
        "abort",
        "",
        genericHint,
        "inconsistent: " + step + " is complete but " + currentStep + " is pending"
      );
      return;
    }
  }

  // The scan passed — persist the snapshot's evidence-resolved steps (#1148).
  // Gated steps reach this point only when their approval verdict already passed
  // inside the snapshot, so the write should succeed; the throw is still handled
  // defensively inside persistResolutions.
  persistResolutions();

  // detail has no usable input when neither the intent nor the outline artifact
  // exists — /make-detail-plan would draft against nothing. This is reachable
  // through post-veto reset (#1681), where detail becomes effective-pending while
  // its upstream artifacts were never produced.
  if (currentStep === "detail" &&
      !hasPlanArtifact("clarify_intent", sid) &&
      !hasPlanArtifact("outline", sid)) {
    emit(
      "blocked", "",
      "detail has no input artifact: neither intent.md nor outline.md exists for this session. " +
        "Run /clarify-intent first, then /make-outline-plan.",
      "detail-input-missing"
    );
    return;
  }

  const skill = STEP_TO_SKILL[currentStep];
  const hint = skill
    ? ("Run /" + skill + " via the Skill tool.")
    : (STEP_HINT[currentStep] || currentStep);

  // #1286 + #1300 hardening #3/#7: authoritative recorded-verdict skip.
  // applyRecordedVerdictSkip reads skip_judgment exactly once (EXPORTED read),
  // validates it, and passes the same object into markStep so the audit record survives.
  // Returns null on any failure/invalid/absent path (caller falls through, no recursion).
  function applyRecordedVerdictSkip(sid, rawSid, stepName, skipReason) {
    try {
      const wfState = require("../../../../hooks/workflow-state");
      const hvsj = wfState.hasValidSkipJudgment;
      const rsjFn = wfState.readSkipJudgment;
      const irvFn = wfState.isRecordedVerdictValid;
      if (typeof hvsj !== "function" || typeof rsjFn !== "function") return null;
      if (!hvsj(sid, stepName)) return null;   // local UNCOUNTED gate read
      const sj = rsjFn(sid, stepName);          // EXPORTED COUNTED read (+1) — exactly once
      if (typeof irvFn !== "function" || !irvFn(sj, stepName)) return null;
      try {
        markStep(sid, stepName, "skipped", { skip_reason: skipReason, skip_judgment: sj });
        // A-4: attach speculative skip verdict (pending-verification). Kept AFTER
        // markStep so the read-modify-write preserves skip_reason/skip_judgment.
        try {
          const wfState2 = require("../../../../hooks/workflow-state");
          if (typeof wfState2.recordSkipVerdict === "function") {
            wfState2.recordSkipVerdict(sid, stepName, "pending", "next-step-recorded-verdict");
          }
        } catch (_) { /* fail-open */ }
        return computeVerdict(rawSid, true);
      } catch (_) {
        return null;   // markStep/verdict failed — fall through, NO recursion
      }
    } catch (_) {
      return null;   // fail-open
    }
  }

  // #485: advisory plan-skip hint at outline/detail only. isTrivial reads
  // intent.md (fail-open to false). next-step only ever sees one current step,
  // and outline precedes detail, so a detail hint surfaces only after outline is
  // complete/skipped — automatically satisfying "emit only WORKFLOW_OUTLINE_NOT_NEEDED
  // when both are skippable". Purely advisory: does not change the verdict.
  // isTrivial is now a WEAK SUPPLEMENTARY hint (demoted from sole gate by #1286).
  let skipHint = "";
  if (currentStep === "outline" || currentStep === "detail") {
    try {
      const { isTrivial } = require("../../../../hooks/workflow-state/skip-signal-resolver");
      if (isTrivial(sid)) {
        skipHint = currentStep === "outline"
          ? "WORKFLOW_OUTLINE_NOT_NEEDED"
          : "WORKFLOW_DETAIL_NOT_NEEDED";
      }
    } catch (e) { /* fail-open: no hint */ }
  }

  emit("invoke", skill, hint, currentStep, skipHint);
}

module.exports = { emit, computeVerdict };
