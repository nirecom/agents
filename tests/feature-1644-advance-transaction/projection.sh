# shellcheck shell=bash
# Tests: hooks/workflow-state/record-step-verdict.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-mark/not-needed-handlers.js, bin/workflow/lib/next-step/advance.js
# Tags: tl2, workflow, advance, projection-equivalence, scope:issue-specific
# #1644 cases A6 / A7 / A14 / A15. Relies on helpers.sh.

run_projection_cases() {
  echo ""
  echo "=== A6: workflow_init complete resets downstream ONLY on transition ==="
  # Transition arm: workflow_init pending -> complete must reset the already
  # complete downstream step, exactly as the sentinel path does today.
  at_wfinit a6t
  check "A6a: fixture starts with research complete" '"complete"' "$(step_status a6t research)"
  run_ns --session a6t --advance --step workflow_init --status complete
  check "A6a: transition exits 0" 0 "$NS_RC"
  check "A6a: downstream research is reset to pending" '"pending"' "$(step_status a6t research)"

  # No-transition arm: workflow_init is ALREADY complete, so a repeat must be a
  # no-op — re-firing the reset here would silently destroy real progress.
  make_state a6n "workflow_init research"
  check "A6b: research is complete before the repeat" '"complete"' "$(step_status a6n research)"
  run_ns --session a6n --advance --step workflow_init --status complete
  check "A6b: repeat exits 0" 0 "$NS_RC"
  check_contains "A6b: repeat reports already=true" "already=true" "$NS_OUT"
  check "A6b: downstream research is NOT reset" '"complete"' "$(step_status a6n research)"

  echo ""
  echo "=== A7: sentinel path and --advance path project the same fact ==="
  # --- skip pair: outline skipped ---
  at_outline a7ss
  run_mark_hook a7ss 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: scope is a single known file>>"'
  at_outline a7sa
  run_ns --session a7sa --advance --step outline --status skipped \
    --skip-reason "scope is a single known file"
  check "A7-skip: advance path exits 0" 0 "$NS_RC"
  check "A7-skip: sentinel path recorded the skip" '"skipped"' "$(step_status a7ss outline)"
  check "A7-skip: projections match (excluding at/origin/provenance)" \
    "$(step_entry a7ss outline)" "$(step_entry a7sa outline)"
  # The 4 excluded fields are asserted against the plan's expectation table
  # instead of being ignored: both paths are declarations, and the origin token
  # is what tells an auditor WHICH declaration route wrote the fact.
  check "A7-skip: sentinel path provenance/origin" \
    '{"provenance":"declared","origin":"mark-step"}' "$(step_audit a7ss outline)"
  check "A7-skip: advance path provenance/origin" \
    '{"provenance":"declared","origin":"next-step-advance"}' "$(step_audit a7sa outline)"
  # A-4 co-write must be identical on both paths (#1681) apart from `source`.
  check "A7-skip: sentinel path co-writes a pending skip_verdict" \
    '"pending"' "$(step_sub a7ss outline skip_verdict.verdict)"
  check "A7-skip: advance path co-writes a pending skip_verdict" \
    '"pending"' "$(step_sub a7sa outline skip_verdict.verdict)"
  check "A7-skip: sentinel path skip_verdict source" \
    '"sentinel"' "$(step_sub a7ss outline skip_verdict.source)"
  check "A7-skip: advance path skip_verdict source" \
    '"advance"' "$(step_sub a7sa outline skip_verdict.source)"

  # --- skip pair: detail skipped ---
  # detail is the OTHER approval-gated sibling (APPROVAL_GATED_STEPS = outline,
  # detail). The expectation table has to hold for it too, otherwise the single
  # writer could be special-casing outline and nothing would notice.
  make_state a7ds "workflow_init clarify_intent research outline"
  run_mark_hook a7ds 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: the file-level plan is already fixed by the issue>>"'
  make_state a7da "workflow_init clarify_intent research outline"
  run_ns --session a7da --advance --step detail --status skipped \
    --skip-reason "the file-level plan is already fixed by the issue"
  check "A7-skip-detail: advance path exits 0" 0 "$NS_RC"
  check "A7-skip-detail: sentinel path recorded the skip" '"skipped"' "$(step_status a7ds detail)"
  check "A7-skip-detail: advance path recorded the skip" '"skipped"' "$(step_status a7da detail)"
  check "A7-skip-detail: projections match (excluding at/origin/provenance)" \
    "$(step_entry a7ds detail)" "$(step_entry a7da detail)"
  check "A7-skip-detail: sentinel path provenance/origin" \
    '{"provenance":"declared","origin":"mark-step"}' "$(step_audit a7ds detail)"
  check "A7-skip-detail: advance path provenance/origin" \
    '{"provenance":"declared","origin":"next-step-advance"}' "$(step_audit a7da detail)"
  check "A7-skip-detail: sentinel path co-writes a pending skip_verdict" \
    '"pending"' "$(step_sub a7ds detail skip_verdict.verdict)"
  check "A7-skip-detail: advance path co-writes a pending skip_verdict" \
    '"pending"' "$(step_sub a7da detail skip_verdict.verdict)"
  check "A7-skip-detail: sentinel path skip_verdict source" \
    '"sentinel"' "$(step_sub a7ds detail skip_verdict.source)"
  check "A7-skip-detail: advance path skip_verdict source" \
    '"advance"' "$(step_sub a7da detail skip_verdict.source)"

  # --- complete pair: research complete via --mark (observed) vs --advance (declared) ---
  at_research a7cm
  run_ns --session a7cm --mark research complete
  check "A7-complete: --mark stdout is unchanged" "MARK=research status=complete" "$NS_OUT"
  at_research a7ca
  run_ns --session a7ca --advance --step research --status complete
  check "A7-complete: advance path exits 0" 0 "$NS_RC"
  check "A7-complete: projections match (excluding at/origin/provenance)" \
    "$(step_entry a7cm research)" "$(step_entry a7ca research)"
  check "A7-complete: --mark path provenance/origin" \
    '{"provenance":"observed","origin":"mark-step"}' "$(step_audit a7cm research)"
  check "A7-complete: advance path provenance/origin" \
    '{"provenance":"declared","origin":"next-step-advance"}' "$(step_audit a7ca research)"

  echo ""
  echo "=== A14: advance skip of an approval-gated step co-writes the A-4 verdict ==="
  # Without the co-write, skip-verifier never gets a chance to veto and the skip
  # becomes final — the exact regression #1681 fixed on the sentinel path.
  at_outline a14
  run_ns --session a14 --advance --step outline --status skipped \
    --skip-reason "approach is already fixed by the issue"
  check "A14a: outline skip exits 0" 0 "$NS_RC"
  check "A14a: skip_verdict.verdict is pending" '"pending"' "$(step_sub a14 outline skip_verdict.verdict)"
  # And the pending verdict must actually reach the verdict engine.
  run_ns --session a14
  check "A14b: a bare next-step call exits 0" 0 "$NS_RC"
  check_contains "A14b: ACTION=blocked" "ACTION=blocked" "$NS_OUT"
  check_contains "A14b: REASON=speculative-skip-pending" "speculative-skip-pending" "$NS_OUT"

  # detail is the symmetric member of the same approval-gated class.
  make_state a14d "workflow_init clarify_intent research outline"
  run_ns --session a14d --advance --step detail --status skipped \
    --skip-reason "single-file change, no file-level plan needed"
  check "A14c: detail skip exits 0" 0 "$NS_RC"
  check "A14c: detail skip_verdict.verdict is pending" '"pending"' "$(step_sub a14d detail skip_verdict.verdict)"

  echo ""
  echo "=== A15: --next declines to advance when the step is not the current step ==="
  # cleanup is skippable but far downstream: recording it must not drag the
  # ACTION block for an unrelated step into the same output.
  at_research a15
  run_ns --session a15 --advance --step cleanup --status skipped \
    --skip-reason "no worktree artifacts to clean" --next
  check "A15: out-of-scope advance still exits 0" 0 "$NS_RC"
  # The record is still reported: "out of scope" means no ACTION block, not a
  # silent write. ADVANCE_SCOPE is what says the ACTION block is absent by
  # design rather than lost.
  check_contains "A15: the record itself is reported" "ADVANCED=cleanup status=skipped" "$NS_OUT"
  check_not_contains "A15: no RECORDED= line is minted by the advance path" "RECORDED=" "$NS_OUT"
  check_contains "A15: ADVANCE_SCOPE=not-current-step" "ADVANCE_SCOPE=not-current-step" "$NS_OUT"
  check "A15: no ACTION line is emitted" 0 "$(action_line_count)"
  check "A15: the record still landed" '"skipped"' "$(step_status a15 cleanup)"

  # Symmetric control: when the step IS the current step, the ACTION block appears
  # and the scope line reports the other verdict of the same classifier.
  at_research a15c
  run_ns --session a15c --advance --step research --status complete --next
  check "A15-control: in-scope advance emits exactly one ACTION line" 1 "$(action_line_count)"
  check_contains "A15-control: ADVANCE_SCOPE=current-step" "ADVANCE_SCOPE=current-step" "$NS_OUT"
  check_not_contains "A15-control: the out-of-scope verdict is NOT reported" \
    "ADVANCE_SCOPE=not-current-step" "$NS_OUT"
}
