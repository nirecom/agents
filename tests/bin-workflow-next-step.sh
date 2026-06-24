#!/usr/bin/env bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, oracle, scope:common
#
# L2 test of the workflow oracle's state-transition resolver and --list renderer.
# Source under test does NOT yet exist (TDD phase A — RED state expected).
#
# L3 gap (what this test does NOT catch):
# - Real CLAUDE_SESSION_ID environment propagation from a live claude -p session
# - Actual workflow-mark.js sentinel dispatch triggering oracle consumption
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPDIR_WT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WT"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_WT"

# Derive oracle path from the test file's own location so worktree runs
# test the worktree's oracle rather than the one in $AGENTS_CONFIG_DIR.
ORACLE_AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 "$@"
  else
    perl -e 'alarm 180; exec @ARGV' -- "$@"
  fi
}

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$expected] got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$needle] in: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

write_state() {
  local sid="$1" json="$2"
  printf '%s' "$json" > "$TMPDIR_WT/${sid}.json"
}

run_oracle() {
  run_with_timeout node "$ORACLE_AGENTS_DIR/bin/workflow/next-step" "$@"
}

# All-pending fixture (closes_issues populated so clarify_intent isn't blocked).
JSON_ALL_PENDING='{"steps":{"workflow_init":{"status":"pending"},"clarify_intent":{"status":"pending"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

JSON_WFINIT_COMPLETE='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"pending"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

JSON_CLARIFY_COMPLETE='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

JSON_RESEARCH_SKIPPED='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"skipped"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

JSON_TESTS_SKIPPED='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"skipped"},"review_tests":{"status":"skipped"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

JSON_WRITE_TESTS_IN_PROGRESS='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"in_progress"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

JSON_ALL_COMPLETE='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"complete"},"review_tests":{"status":"complete"},"run_tests":{"status":"complete"},"review_security":{"status":"complete"},"docs":{"status":"complete"},"user_verification":{"status":"complete"},"cleanup":{"status":"complete"},"pre_final_report_gate":{"status":"complete"}},"closes_issues":[1053]}'

JSON_MIXED_TERMINAL='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"skipped"},"outline":{"status":"skipped"},"detail":{"status":"skipped"},"branching_complete":{"status":"complete"},"write_tests":{"status":"skipped"},"review_tests":{"status":"skipped"},"run_tests":{"status":"complete"},"review_security":{"status":"skipped"},"docs":{"status":"complete"},"user_verification":{"status":"complete"},"cleanup":{"status":"skipped"},"pre_final_report_gate":{"status":"complete"}},"closes_issues":[1053]}'

# closes_issues blocked: clarify_intent is next step but closes_issues is empty.
JSON_BLOCKED='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"pending"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[]}'

# closes_issues absent, but we've already passed clarify_intent — should NOT be blocked.
JSON_NOT_BLOCKED='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}}}'

JSON_CORRUPT='{invalid json'

# review_tests complete while write_tests still pending — impossible ordering.
JSON_INCONSISTENT='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"pending"},"review_tests":{"status":"complete"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

# Cross-task contamination: workflow_init+clarify_intent just ran (new session start), but
# pre_final_report_gate is complete from a prior workflow on the same CC session UUID (#1068).
JSON_CROSS_TASK_CONTAM='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"pending"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"complete"}},"closes_issues":[1053]}'

# Mixed-state fixture for --list (case 15): a few complete, one skipped, current is detail.
JSON_LIST_MIXED='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"skipped"},"outline":{"status":"complete"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

# Missing-step schema: research key absent (treated as pending); all other 13 steps explicit.
# branching_complete is explicitly pending to prevent readState() migration from synthesizing it
# as complete (migration adds branching_complete=complete when the key is absent).
JSON_MISSING_STEP='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

# Empty steps object: all steps absent. readState() migration synthesizes workflow_init,
# clarify_intent, and branching_complete as complete — creating an inconsistency with the
# absent research step (idx 2). Oracle returns ACTION=abort, not ACTION=invoke.
JSON_EMPTY_STEPS='{"steps":{},"closes_issues":[1053]}'

# Non-skill step fixtures: branching_complete and user_verification should emit NEXT_SKILL="" + NEXT_HINT non-empty.
JSON_BRANCHING_NEXT='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'
JSON_USER_VERIFICATION_NEXT='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"complete"},"review_tests":{"status":"complete"},"run_tests":{"status":"complete"},"review_security":{"status":"complete"},"docs":{"status":"complete"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

# WF-PLAN: detail complete, non-applicable steps pending, pre_final_report_gate pending
JSON_WF_PLAN_AT_PREFINAL='{"workflow_type":"wf-plan","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[721]}'

# WF-PLAN: all applicable steps complete, non-applicable pending, pre_final_report_gate complete
JSON_WF_PLAN_ALL_DONE='{"workflow_type":"wf-plan","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"complete"}},"closes_issues":[721]}'

# WF-PLAN mid-planning: workflow_init complete, clarify_intent pending
JSON_WF_PLAN_MID='{"workflow_type":"wf-plan","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"pending"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[721]}'

# WF-CODE with explicit workflow_type field (regression: must be unaffected by WF-PLAN logic)
JSON_WF_CODE_EXPLICIT='{"workflow_type":"wf-code","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

run_tests() {
  local OUT ACTION NEXT_SKILL NEXT_HINT REASON

  # ---- Case 1: no-state-file ------------------------------------------------
  ACTION=""; NEXT_SKILL=""
  OUT="$(run_oracle --session "nonexistent-$$" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "1: no-state-file ACTION=invoke" "invoke" "${ACTION:-}"
  check "1: no-state-file NEXT_SKILL=workflow-init" "workflow-init" "${NEXT_SKILL:-}"

  # ---- Case 2: all-pending --------------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case2" "$JSON_ALL_PENDING"
  OUT="$(run_oracle --session "case2" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "2: all-pending ACTION=invoke" "invoke" "${ACTION:-}"
  check "2: all-pending NEXT_SKILL=workflow-init" "workflow-init" "${NEXT_SKILL:-}"

  # ---- Case 3: workflow_init-complete --------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case3" "$JSON_WFINIT_COMPLETE"
  OUT="$(run_oracle --session "case3" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "3: workflow_init-complete ACTION=invoke" "invoke" "${ACTION:-}"
  check "3: workflow_init-complete NEXT_SKILL=clarify-intent" "clarify-intent" "${NEXT_SKILL:-}"

  # ---- Case 4: clarify_intent-complete -------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case4" "$JSON_CLARIFY_COMPLETE"
  OUT="$(run_oracle --session "case4" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "4: clarify_intent-complete ACTION=invoke" "invoke" "${ACTION:-}"
  check "4: clarify_intent-complete NEXT_SKILL=survey-code" "survey-code" "${NEXT_SKILL:-}"

  # ---- Case 5: research-skipped --------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case5" "$JSON_RESEARCH_SKIPPED"
  OUT="$(run_oracle --session "case5" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "5: research-skipped ACTION=invoke" "invoke" "${ACTION:-}"
  check "5: research-skipped NEXT_SKILL=make-outline-plan" "make-outline-plan" "${NEXT_SKILL:-}"

  # ---- Case 6: write_tests + review_tests skipped --------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case6" "$JSON_TESTS_SKIPPED"
  OUT="$(run_oracle --session "case6" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "6: tests-skipped ACTION=invoke" "invoke" "${ACTION:-}"
  check "6: tests-skipped NEXT_SKILL=run-tests" "run-tests" "${NEXT_SKILL:-}"

  # ---- Case 7: in_progress step --------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case7" "$JSON_WRITE_TESTS_IN_PROGRESS"
  OUT="$(run_oracle --session "case7" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "7: in_progress ACTION=invoke" "invoke" "${ACTION:-}"
  check "7: in_progress NEXT_SKILL=write-tests" "write-tests" "${NEXT_SKILL:-}"

  # ---- Case 8: all-complete -------------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case8" "$JSON_ALL_COMPLETE"
  OUT="$(run_oracle --session "case8" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "8: all-complete ACTION=done" "done" "${ACTION:-}"
  check "8: all-complete NEXT_SKILL empty" "" "${NEXT_SKILL:-}"

  # ---- Case 9: mixed-terminal ----------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case9" "$JSON_MIXED_TERMINAL"
  OUT="$(run_oracle --session "case9" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "9: mixed-terminal ACTION=done" "done" "${ACTION:-}"
  check "9: mixed-terminal NEXT_SKILL empty" "" "${NEXT_SKILL:-}"

  # ---- Case 10: closes_issues-blocked --------------------------------------
  ACTION=""; REASON=""
  write_state "case10" "$JSON_BLOCKED"
  OUT="$(run_oracle --session "case10" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "10: closes_issues-blocked ACTION=blocked" "blocked" "${ACTION:-}"
  check_contains "10: closes_issues-blocked REASON marker" "closes_issues-empty" "${REASON:-}"

  # ---- Case 11: closes_issues-not-blocked (past clarify_intent) ------------
  ACTION=""; NEXT_SKILL=""
  write_state "case11" "$JSON_NOT_BLOCKED"
  OUT="$(run_oracle --session "case11" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "11: closes_issues-not-blocked ACTION=invoke" "invoke" "${ACTION:-}"

  # ---- Case 12: corrupt-state ----------------------------------------------
  ACTION=""; REASON=""
  write_state "case12" "$JSON_CORRUPT"
  OUT="$(run_oracle --session "case12" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "12: corrupt-state ACTION=abort" "abort" "${ACTION:-}"
  check_contains "12: corrupt-state REASON marker" "corrupt-state:" "${REASON:-}"

  # ---- Case 13: inconsistent-state -----------------------------------------
  ACTION=""; REASON=""
  write_state "case13" "$JSON_INCONSISTENT"
  OUT="$(run_oracle --session "case13" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "13: inconsistent-state ACTION=abort" "abort" "${ACTION:-}"
  check_contains "13: inconsistent-state REASON marker" "inconsistent:" "${REASON:-}"

  # ---- Case 13b: cross-task contamination (#1068) --------------------------
  # pre_final_report_gate=complete from a prior workflow run; clarify_intent=pending now.
  # Oracle must abort with a non-empty NEXT_HINT (recovery hint).
  ACTION=""; REASON=""; NEXT_HINT=""
  write_state "case13b" "$JSON_CROSS_TASK_CONTAM"
  OUT="$(run_oracle --session "case13b" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "13b: cross-task-contam ACTION=abort" "abort" "${ACTION:-}"
  check_contains "13b: cross-task-contam REASON marker" "inconsistent:" "${REASON:-}"
  if [ -n "${NEXT_HINT:-}" ]; then
    echo "PASS: 13b: cross-task-contam NEXT_HINT non-empty"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 13b: cross-task-contam NEXT_HINT should be non-empty (got empty)"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 14: --list (no session) ----------------------------------------
  local LIST_OUT LINE_COUNT
  LIST_OUT="$(run_oracle --list 2>/dev/null || true)"
  LINE_COUNT="$(printf '%s\n' "$LIST_OUT" | grep -c . || true)"
  check "14a: --list emits 14 rows" "14" "$LINE_COUNT"

  local step
  local missing=0
  for step in workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate; do
    if ! echo "$LIST_OUT" | grep -qF "$step"; then
      echo "FAIL: 14b: --list missing step name [$step]"
      FAIL=$((FAIL + 1))
      missing=1
    fi
  done
  if [ "$missing" = "0" ]; then
    echo "PASS: 14b: --list contains all 14 step names"
    PASS=$((PASS + 1))
  fi

  # Each row matches "<digits><whitespace><snake_case>"
  local row_fail=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if ! echo "$line" | grep -Eq '[0-9]+[[:space:]]+[a-z_]+'; then
      echo "FAIL: 14c: row does not match index+name pattern -- [$line]"
      FAIL=$((FAIL + 1))
      row_fail=1
      break
    fi
  done <<< "$LIST_OUT"
  if [ "$row_fail" = "0" ]; then
    echo "PASS: 14c: every --list row matches index+name pattern"
    PASS=$((PASS + 1))
  fi

  # ---- Case 15: --list --session <sid> with mixed state --------------------
  write_state "case15" "$JSON_LIST_MIXED"
  local MIXED_OUT
  MIXED_OUT="$(run_oracle --list --session "case15" 2>/dev/null || true)"

  local line_wf line_research line_outline line_detail
  line_wf="$(echo "$MIXED_OUT" | grep -E 'workflow_init([^a-z_]|$)' | head -n1 || true)"
  line_research="$(echo "$MIXED_OUT" | grep -E 'research([^a-z_]|$)' | head -n1 || true)"
  line_outline="$(echo "$MIXED_OUT" | grep -E 'outline([^a-z_]|$)' | head -n1 || true)"
  line_detail="$(echo "$MIXED_OUT" | grep -E 'detail([^a-z_]|$)' | head -n1 || true)"

  check_contains "15a: complete step shows [x]" "[x]" "$line_wf"
  check_contains "15b: skipped step shows [-]" "[-]" "$line_research"
  check_contains "15c: complete step (outline) shows [x]" "[x]" "$line_outline"
  check_contains "15d: current step (detail) shows [*]" "[*]" "$line_detail"

  # branching_complete is pending -> should show "[ ]"
  local line_branching
  line_branching="$(echo "$MIXED_OUT" | grep -E 'branching_complete' | head -n1 || true)"
  check_contains "15e: pending step shows [ ]" "[ ]" "$line_branching"

  # ---- Case 16: --list [!] blocked overlay ---------------------------------
  write_state "case16" "$JSON_BLOCKED"
  local BLOCKED_LIST
  BLOCKED_LIST="$(run_oracle --list --session "case16" 2>/dev/null || true)"
  local line_clarify
  line_clarify="$(echo "$BLOCKED_LIST" | grep -E 'clarify_intent' | head -n1 || true)"
  check_contains "16: clarify_intent row shows [!] overlay" "[!]" "$line_clarify"

  # ---- Case 17: --list --session <missing-sid> -----------------------------
  local PLAIN_LIST MISSING_LIST
  PLAIN_LIST="$(run_oracle --list 2>/dev/null || true)"
  MISSING_LIST="$(run_oracle --list --session "absent-sid-xyz-$$" 2>/dev/null || true)"
  check "17: --list with missing sid matches plain --list" "$PLAIN_LIST" "$MISSING_LIST"

  # ---- Case 18: missing-step schema ----------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case18" "$JSON_MISSING_STEP"
  OUT="$(run_oracle --session "case18" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "18: missing-step ACTION=invoke" "invoke" "${ACTION:-}"
  check "18: missing-step NEXT_SKILL=survey-code" "survey-code" "${NEXT_SKILL:-}"

  # ---- Case 18b: empty steps object ----------------------------------------
  # Migration synthesizes complete for workflow_init, clarify_intent, branching_complete
  # when all keys are absent — inconsistent with absent research (pending) at idx 2.
  ACTION=""; REASON=""
  write_state "case18b" "$JSON_EMPTY_STEPS"
  OUT="$(run_oracle --session "case18b" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "18b: empty-steps ACTION=abort" "abort" "${ACTION:-}"
  check_contains "18b: empty-steps REASON marker" "inconsistent:" "${REASON:-}"

  # ---- Case 19: idempotency -------------------------------------------------
  write_state "case19" "$JSON_WFINIT_COMPLETE"
  local OUT1 OUT2
  OUT1="$(run_oracle --session "case19" 2>/dev/null || true)"
  OUT2="$(run_oracle --session "case19" 2>/dev/null || true)"
  check "19: idempotency same output on re-run" "$OUT1" "$OUT2"

  # ---- Case 20: security -- path traversal in --session arg ----------------
  # next-step now validates --session against [A-Za-z0-9_-]+ → exits non-zero.
  rc=0
  run_oracle --session "../evil-$$" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 20: path-traversal --session rejected (exit $rc)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 20: path-traversal --session should be rejected"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 20b: security -- shell metachar injection in --session arg ------
  # Validation rejects meta characters ([A-Za-z0-9_-]+ allowlist) → exits non-zero.
  rc=0
  run_oracle --session 'foo;bar$(evil)' 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 20b: metachar injection rejected (exit $rc)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 20b: metachar injection should be rejected"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 20c: empty string session boundary ------------------------------
  ACTION=""
  OUT="$(run_oracle --session "" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  if [ -n "${ACTION:-}" ]; then
    echo "PASS: 20c: empty session yields valid ACTION (${ACTION})"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 20c: empty session produced empty ACTION (silent crash)"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 21: --list shows [*] for in_progress step ----------------------
  write_state "case21" "$JSON_WRITE_TESTS_IN_PROGRESS"
  local IN_PROG_LIST line_write_tests
  IN_PROG_LIST="$(run_oracle --list --session "case21" 2>/dev/null || true)"
  line_write_tests="$(echo "$IN_PROG_LIST" | grep -E 'write_tests' | head -n1 || true)"
  check_contains "21: in_progress step shows [*] in --list" "[*]" "$line_write_tests"

  # ---- Case 22a: non-skill step (branching_complete) — NEXT_SKILL empty -----
  ACTION=""; NEXT_SKILL="SENTINEL"; NEXT_HINT=""
  write_state "case22a" "$JSON_BRANCHING_NEXT"
  OUT="$(run_oracle --session "case22a" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "22a: branching_complete ACTION=invoke" "invoke" "${ACTION:-}"
  check "22a: branching_complete NEXT_SKILL empty" "" "${NEXT_SKILL:-}"
  if [ -n "${NEXT_HINT:-}" ]; then
    echo "PASS: 22a: branching_complete NEXT_HINT non-empty"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 22a: branching_complete NEXT_HINT should be non-empty"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 22b: non-skill step (user_verification) — NEXT_SKILL empty ------
  ACTION=""; NEXT_SKILL="SENTINEL"; NEXT_HINT=""
  write_state "case22b" "$JSON_USER_VERIFICATION_NEXT"
  OUT="$(run_oracle --session "case22b" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "22b: user_verification ACTION=invoke" "invoke" "${ACTION:-}"
  check "22b: user_verification NEXT_SKILL empty" "" "${NEXT_SKILL:-}"
  if [ -n "${NEXT_HINT:-}" ]; then
    echo "PASS: 22b: user_verification NEXT_HINT non-empty"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 22b: user_verification NEXT_HINT should be non-empty"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 23: unknown CLI flag → exit non-zero ----------------------------
  local unk_rc=0
  run_oracle --unknown-flag-xyz >/dev/null 2>/dev/null || unk_rc=$?
  if [ "$unk_rc" -ne 0 ]; then
    echo "PASS: 23: unknown flag exits non-zero ($unk_rc)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 23: unknown flag should exit non-zero but exited 0"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 24: WF-PLAN — detail done → pre_final_report_gate (auto-skip non-applicable) ----
  ACTION=""; NEXT_SKILL=""; REASON=""
  write_state "case24" "$JSON_WF_PLAN_AT_PREFINAL"
  OUT="$(run_oracle --session "case24" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "24: wf-plan detail-done ACTION=invoke" "invoke" "${ACTION:-}"
  check_contains "24: wf-plan detail-done REASON=pre_final_report_gate" "pre_final_report_gate" "${REASON:-}"

  # ---- Case 25: WF-PLAN — all applicable steps done → done ----------------------
  ACTION=""
  write_state "case25" "$JSON_WF_PLAN_ALL_DONE"
  OUT="$(run_oracle --session "case25" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "25: wf-plan all-done ACTION=done" "done" "${ACTION:-}"

  # ---- Case 26: WF-PLAN mid-planning — clarify_intent pending ------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case26" "$JSON_WF_PLAN_MID"
  OUT="$(run_oracle --session "case26" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "26: wf-plan mid ACTION=invoke" "invoke" "${ACTION:-}"
  check "26: wf-plan mid NEXT_SKILL=clarify-intent" "clarify-intent" "${NEXT_SKILL:-}"

  # ---- Case 27: WF-CODE explicit type — existing behavior unaffected -----------
  ACTION=""; NEXT_SKILL=""
  write_state "case27" "$JSON_WF_CODE_EXPLICIT"
  OUT="$(run_oracle --session "case27" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "27: wf-code explicit type NEXT_SKILL=survey-code" "survey-code" "${NEXT_SKILL:-}"

  # ---- Case 28: WF-PLAN --list shows [-] for auto-skipped steps ---------------
  write_state "case28" "$JSON_WF_PLAN_AT_PREFINAL"
  PLAN_LIST="$(run_oracle --list --session "case28" 2>/dev/null || true)"
  line_branching28="$(echo "$PLAN_LIST" | grep -E 'branching_complete' | head -n1 || true)"
  line_uv28="$(echo "$PLAN_LIST" | grep -E 'user_verification' | head -n1 || true)"
  check_contains "28a: wf-plan --list branching_complete shows [-]" "[-]" "$line_branching28"
  check_contains "28b: wf-plan --list user_verification shows [-]" "[-]" "$line_uv28"
}

# run_with_timeout wraps each individual `node` invocation inside run_oracle
# (timeout/perl-exec cannot wrap shell functions directly, so per-call bounding
# is the portable shape — matches tests/feature-1027-state-schema-eligible-phase.sh).
run_tests

echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
