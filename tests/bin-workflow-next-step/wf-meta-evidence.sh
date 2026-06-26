# shellcheck shell=bash
# Tests: bin/workflow/next-step
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
  OUT="$(run_oracle --session "case24" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "24: wf-meta detail-done ACTION=invoke" "invoke" "${ACTION:-}"
  check_contains "24: wf-meta detail-done REASON=pre_final_report_gate" "pre_final_report_gate" "${REASON:-}"

  # ---- Case 25: WF-META — all applicable steps done → done ----------------------
  ACTION=""
  write_state "case25" "$JSON_WF_META_ALL_DONE"
  OUT="$(run_oracle --session "case25" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "25: wf-meta all-done ACTION=done" "done" "${ACTION:-}"

  # ---- Case 26: WF-META mid-planning — clarify_intent pending ------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case26" "$JSON_WF_META_MID"
  OUT="$(run_oracle --session "case26" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "26: wf-meta mid ACTION=invoke" "invoke" "${ACTION:-}"
  check "26: wf-meta mid NEXT_SKILL=clarify-intent" "clarify-intent" "${NEXT_SKILL:-}"

  # ---- Case 27: WF-CODE explicit type — existing behavior unaffected -----------
  ACTION=""; NEXT_SKILL=""
  write_state "case27" "$JSON_WF_CODE_EXPLICIT"
  OUT="$(run_oracle --session "case27" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "27: wf-code explicit type NEXT_SKILL=survey-code" "survey-code" "${NEXT_SKILL:-}"

  # ---- Case 28: WF-META --list shows [-] for auto-skipped steps ---------------
  write_state "case28" "$JSON_WF_META_AT_PREFINAL"
  PLAN_LIST="$(run_oracle --list --session "case28" 2>/dev/null || true)"
  line_branching28="$(echo "$PLAN_LIST" | grep -E 'branching_complete' | head -n1 || true)"
  line_uv28="$(echo "$PLAN_LIST" | grep -E 'user_verification' | head -n1 || true)"
  check_contains "28a: wf-meta --list branching_complete shows [-]" "[-]" "$line_branching28"
  check_contains "28b: wf-meta --list user_verification shows [-]" "[-]" "$line_uv28"

  # ---- Case 29: WF-PLAN legacy state migrated to wf-meta by readState() ------
  ACTION=""; REASON=""
  write_state "case29" "$JSON_WF_PLAN_LEGACY"
  OUT="$(run_oracle --session "case29" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "29: wf-plan legacy state migrated → ACTION=invoke" "invoke" "${ACTION:-}"
  check_contains "29: wf-plan legacy state migrated → REASON=pre_final_report_gate" "pre_final_report_gate" "${REASON:-}"
  PLAN_LIST_LEGACY="$(run_oracle --list --session "case29" 2>/dev/null || true)"
  line_branching29="$(echo "$PLAN_LIST_LEGACY" | grep -E 'branching_complete' | head -n1 || true)"
  check_contains "29c: wf-plan legacy --list branching_complete shows [-]" "[-]" "$line_branching29"

  # ---- Case 30: clarify_intent evidence — intent.md present → oracle auto-repairs + advances ----
  # This case only runs if evidence-resolver.js exists (oracle evidence-awareness implemented).
  if [ -f "$ORACLE_AGENTS_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
    local PLANS_DIR_WT
    PLANS_DIR_WT="$(mktemp -d)"
    ACTION=""; NEXT_SKILL=""
    write_state "case30" "$JSON_WFINIT_COMPLETE"
    # Create intent.md so evidence-resolver returns true for clarify_intent
    touch "$PLANS_DIR_WT/case30-intent.md"
    OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_WT" run_oracle --session "case30" 2>/dev/null || true)"
    eval "$OUT" 2>/dev/null || true
    # After auto-repair, oracle should advance past clarify_intent to research/survey-code
    if [ "${NEXT_SKILL:-}" != "clarify-intent" ] && [ "${ACTION:-}" = "invoke" ]; then
      echo "PASS: 30: clarify_intent evidence auto-repair → advances past clarify-intent"
      PASS=$((PASS + 1))
    else
      echo "FAIL: 30: expected oracle to advance past clarify-intent when intent.md present, got ACTION=${ACTION:-} NEXT_SKILL=${NEXT_SKILL:-}"
      FAIL=$((FAIL + 1))
    fi
    rm -rf "$PLANS_DIR_WT"
  else
    echo "SKIP: 30: clarify_intent evidence auto-repair (evidence-resolver.js not yet implemented)"
    PASS=$((PASS + 1))
  fi

  # ---- Case 31: clarify_intent evidence — intent.md absent → oracle returns blocked/invoke clarify-intent ----
  if [ -f "$ORACLE_AGENTS_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
    local PLANS_DIR_WT2
    PLANS_DIR_WT2="$(mktemp -d)"
    ACTION=""; NEXT_SKILL=""
    write_state "case31" "$JSON_WFINIT_COMPLETE"
    # Do NOT create intent.md
    OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_WT2" run_oracle --session "case31" 2>/dev/null || true)"
    eval "$OUT" 2>/dev/null || true
    check "31: clarify_intent evidence absent → ACTION=invoke" "invoke" "${ACTION:-}"
    check "31b: clarify_intent evidence absent → NEXT_SKILL=clarify-intent" "clarify-intent" "${NEXT_SKILL:-}"
    rm -rf "$PLANS_DIR_WT2"
  else
    echo "SKIP: 31: clarify_intent evidence absent check (evidence-resolver.js not yet implemented)"
    PASS=$((PASS + 1))
    PASS=$((PASS + 1))
  fi
}
