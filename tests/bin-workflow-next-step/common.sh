# shellcheck shell=bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, wf-meta, scope:common
#
# Shared helpers + JSON fixtures for the bin-workflow-next-step dispatcher.
# Sourced by bin-workflow-next-step.sh and the case-group files in this folder.

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

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "FAIL: $desc -- did NOT expect [$needle] in: $haystack"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

write_state() {
  local sid="$1" json="$2"
  printf '%s' "$json" > "$TMPDIR_WT/${sid}.json"
}

run_next_step() {
  run_with_timeout node "$NEXT_STEP_AGENTS_DIR/bin/workflow/next-step" "$@"
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
# absent research step (idx 2). next-step returns ACTION=abort, not ACTION=invoke.
JSON_EMPTY_STEPS='{"steps":{},"closes_issues":[1053]}'

# Non-skill step fixtures: branching_complete and user_verification should emit NEXT_SKILL="" + NEXT_HINT non-empty.
JSON_BRANCHING_NEXT='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'
JSON_USER_VERIFICATION_NEXT='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"complete"},"review_tests":{"status":"complete"},"run_tests":{"status":"complete"},"review_security":{"status":"complete"},"docs":{"status":"complete"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

# WF-META: detail complete, non-applicable steps pending, pre_final_report_gate pending
JSON_WF_META_AT_PREFINAL='{"workflow_type":"wf-meta","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[721]}'

# WF-META: all applicable steps complete, non-applicable pending, pre_final_report_gate complete
JSON_WF_META_ALL_DONE='{"workflow_type":"wf-meta","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"complete"}},"closes_issues":[721]}'

# WF-META mid-planning: workflow_init complete, clarify_intent pending
JSON_WF_META_MID='{"workflow_type":"wf-meta","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"pending"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[721]}'

# WF-CODE with explicit workflow_type field (regression: must be unaffected by WF-META logic)
JSON_WF_CODE_EXPLICIT='{"workflow_type":"wf-code","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"pending"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

# migration: old wf-plan state file must be treated as wf-meta via readState() migration shim
JSON_WF_PLAN_LEGACY='{"workflow_type":"wf-plan","steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[721]}'
