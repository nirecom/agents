# shellcheck shell=bash
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: L2, workflow, wf-meta, scope:common
#
# Case group: WF-META workflow type + clarify_intent evidence auto-repair (cases 24–31).
# Sourced by bin-workflow-next-step.sh; relies on helpers/fixtures from common.sh.

run_wf_meta_evidence_tests() {
  local OUT ACTION NEXT_SKILL REASON
  local PLAN_LIST line_branching28 line_uv28
  local PLAN_LIST_LEGACY line_branching29

  # ---- Case 24: WF-META — detail done → pre_final_report_gate (auto-skip non-applicable) ----
  ACTION=""; NEXT_SKILL=""; REASON=""
  write_state "case24" "$JSON_WF_META_AT_PREFINAL"
  OUT="$(run_next_step --session "case24" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "24: wf-meta detail-done ACTION=invoke" "invoke" "${ACTION:-}"
  check_contains "24: wf-meta detail-done REASON=pre_final_report_gate" "pre_final_report_gate" "${REASON:-}"

  # ---- Case 25: WF-META — all applicable steps done → done ----------------------
  ACTION=""
  write_state "case25" "$JSON_WF_META_ALL_DONE"
  OUT="$(run_next_step --session "case25" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "25: wf-meta all-done ACTION=done" "done" "${ACTION:-}"

  # ---- Case 26: WF-META mid-planning — clarify_intent pending ------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case26" "$JSON_WF_META_MID"
  write_intent_issues "case26" 721
  OUT="$(run_next_step --session "case26" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "26: wf-meta mid ACTION=invoke" "invoke" "${ACTION:-}"
  check "26: wf-meta mid NEXT_SKILL=clarify-intent" "clarify-intent" "${NEXT_SKILL:-}"

  # ---- Case 27: WF-CODE explicit type — existing behavior unaffected -----------
  ACTION=""; NEXT_SKILL=""
  write_state "case27" "$JSON_WF_CODE_EXPLICIT"
  OUT="$(run_next_step --session "case27" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "27: wf-code explicit type NEXT_SKILL=survey-code" "survey-code" "${NEXT_SKILL:-}"

  # ---- Case 28: WF-META --list shows [-] for auto-skipped steps ---------------
  write_state "case28" "$JSON_WF_META_AT_PREFINAL"
  PLAN_LIST="$(run_next_step --list --session "case28" 2>/dev/null || true)"
  line_branching28="$(echo "$PLAN_LIST" | grep -E 'branching_complete' | head -n1 || true)"
  line_uv28="$(echo "$PLAN_LIST" | grep -E 'user_verification' | head -n1 || true)"
  check_contains "28a: wf-meta --list branching_complete shows [-]" "[-]" "$line_branching28"
  check_contains "28b: wf-meta --list user_verification shows [-]" "[-]" "$line_uv28"

  # ---- Case 29: WF-PLAN legacy state migrated to wf-meta by readState() ------
  ACTION=""; REASON=""
  write_state "case29" "$JSON_WF_PLAN_LEGACY"
  OUT="$(run_next_step --session "case29" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "29: wf-plan legacy state migrated → ACTION=invoke" "invoke" "${ACTION:-}"
  check_contains "29: wf-plan legacy state migrated → REASON=pre_final_report_gate" "pre_final_report_gate" "${REASON:-}"
  PLAN_LIST_LEGACY="$(run_next_step --list --session "case29" 2>/dev/null || true)"
  line_branching29="$(echo "$PLAN_LIST_LEGACY" | grep -E 'branching_complete' | head -n1 || true)"
  check_contains "29c: wf-plan legacy --list branching_complete shows [-]" "[-]" "$line_branching29"

  # ---- Case 30: clarify_intent evidence — intent.md present → next-step auto-repairs + advances ----
  # This case only runs if evidence-resolver.js exists (next-step evidence-awareness implemented).
  if [ -f "$NEXT_STEP_AGENTS_DIR/hooks/workflow-state/evidence-resolver.js" ]; then
    local PLANS_DIR_WT
    PLANS_DIR_WT="$(mktemp -d)"
    ACTION=""; NEXT_SKILL=""
    write_state "case30" "$JSON_WFINIT_COMPLETE"
    # Create intent.md so evidence-resolver returns true for clarify_intent
    # Since #2277/#2513 the artifact alone no longer completes clarify_intent: the auto-repair also
    # needs the user's approval record, so seed both (the fixture writes intent.md into the pinned plans dir).
    # intent.md names an issue first: the closes_issues gate reads it (#2654) and the fixture keeps an existing file.
    WORKFLOW_PLANS_DIR="$PLANS_DIR_WT" write_intent_issues "case30" 1053
    WORKFLOW_PLANS_DIR="$PLANS_DIR_WT" node "$NEXT_STEP_AGENTS_DIR/tests/lib/plan-approval-fixture.js" approve case30 clarify_intent >/dev/null 2>&1
    # #2529: the auto-repair also needs the intent stage's glossary_check record, taken against
    # the same plans dir and fixture repo the next-step run below recomputes it from.
    local C30_REPO
    C30_REPO="$(mk_glossary_repo "$TMPDIR_WT/case30-repo")"
    WORKFLOW_PLANS_DIR="$PLANS_DIR_WT" glossary_check_record "case30" "$C30_REPO" intent
    OUT="$(cd "$C30_REPO" && WORKFLOW_PLANS_DIR="$PLANS_DIR_WT" CLAUDE_PROJECT_DIR="$C30_REPO" run_next_step --session "case30" 2>/dev/null || true)"
    eval "$OUT" 2>/dev/null || true
    # After auto-repair, next-step should advance past clarify_intent to research/survey-code
    if [ "${NEXT_SKILL:-}" != "clarify-intent" ] && [ "${ACTION:-}" = "invoke" ]; then
      echo "PASS: 30: clarify_intent evidence auto-repair → advances past clarify-intent"
      PASS=$((PASS + 1))
    else
      echo "FAIL: 30: expected next-step to advance past clarify-intent when intent.md present, got ACTION=${ACTION:-} NEXT_SKILL=${NEXT_SKILL:-}"
      FAIL=$((FAIL + 1))
    fi
    rm -rf "$PLANS_DIR_WT"
  else
    echo "SKIP: 30: clarify_intent evidence auto-repair (evidence-resolver.js not yet implemented)"
    PASS=$((PASS + 1))
  fi

  # ---- Case 31: clarify_intent evidence — intent.md absent → next-step blocks on closes_issues-empty ----
  if [ -f "$NEXT_STEP_AGENTS_DIR/hooks/workflow-state/evidence-resolver.js" ]; then
    local PLANS_DIR_WT2
    PLANS_DIR_WT2="$(mktemp -d)"
    ACTION=""; NEXT_SKILL=""; REASON=""
    write_state "case31" "$JSON_WFINIT_COMPLETE"
    # Do NOT create intent.md: the gate reads intent.md (#2654), so the state's recorded
    # closes_issues no longer unblocks clarify_intent.
    OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_WT2" run_next_step --session "case31" 2>/dev/null || true)"
    eval "$OUT" 2>/dev/null || true
    check "31: clarify_intent evidence absent → ACTION=blocked" "blocked" "${ACTION:-}"
    check_contains "31b: clarify_intent evidence absent → REASON closes_issues-empty" "closes_issues-empty" "${REASON:-}"
    rm -rf "$PLANS_DIR_WT2"
  else
    echo "SKIP: 31: clarify_intent evidence absent check (evidence-resolver.js not yet implemented)"
    PASS=$((PASS + 1))
    PASS=$((PASS + 1))
  fi
}
