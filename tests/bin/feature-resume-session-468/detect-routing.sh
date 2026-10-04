# shellcheck shell=bash
# tests/bin/feature-resume-session-468/detect-routing.sh — T1, T3-T20: local detect routing and exit codes. Sourced by tests/bin/feature-resume-session-468.sh; not standalone.
# Tests: bin/resume-session-detect
# Tags: session, resume, workflow, bin, tests, scope:common, pwsh-not-required, TL2

if ! declare -F run_cli >/dev/null 2>&1; then
    echo "detect-routing.sh: sourced fragment — run tests/bin/feature-resume-session-468.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

echo "=== T1: none_when_no_session_id ==="
run_cli "t1" "" "" ""
assert_type "T1. type=none when no session id is supplied" "none"
assert_exit "T1. exit 0 when no session id is supplied" "0"

echo ""
echo "=== T3: none_when_state_missing ==="
run_cli "t3" "test-session-001" "" ""
assert_type "T3. type=none when state file missing" "none"
assert_exit "T3. exit 0 when state file missing" "0"

echo ""
echo "=== T4: none_when_all_pending ==="
T4_JSON=$(build_state_json "test-session-001" "")
run_cli "t4" "test-session-001" "$T4_JSON" ""
assert_type "T4. type=none when all steps pending" "none"
assert_exit "T4. exit 0 when all steps pending" "0"

echo ""
echo "=== T5-T11: skill mapping ==="

run_skill_case() {
    local tname="$1" subdir="$2" step="$3" expected_skill="$4"
    local sid="sid-$subdir"
    local json
    json=$(build_state_json "$sid" "$step")
    run_cli "$subdir" "$sid" "$json" ""
    assert_type "$tname. type=skill when $step in_progress" "skill"
    assert_field "$tname. step=$step" "step" "$step"
    assert_field "$tname. skill=$expected_skill" "skill" "$expected_skill"
}

run_skill_case "T5"  "t5"  "clarify_intent" "clarify-intent"
run_skill_case "T6a" "t6a" "outline"        "make-outline-plan"
run_skill_case "T6b" "t6b" "detail"         "make-detail-plan"
run_skill_case "T7"  "t7"  "write_tests"    "write-tests"
run_skill_case "T8"  "t8"  "run_tests"      "run-tests"
run_skill_case "T9"  "t9"  "docs"           "update-docs"
run_skill_case "T10" "t10" "cleanup"        "worktree-end"
run_skill_case "T11" "t11" "workflow_init"  "workflow-init"

echo ""
echo "=== T12-T15: sentinel-wait steps ==="

run_sentinel_case() {
    local tname="$1" subdir="$2" step="$3"
    local sid="sid-$subdir"
    local json
    json=$(build_state_json "$sid" "$step")
    run_cli "$subdir" "$sid" "$json" ""
    assert_type "$tname. type=sentinel-wait when $step in_progress" "sentinel-wait"
    assert_field "$tname. step=$step" "step" "$step"
}

run_sentinel_case "T12" "t12" "user_verification"
run_sentinel_case "T13" "t13" "branching_complete"
run_sentinel_case "T14" "t14" "research"
run_sentinel_case "T15" "t15" "review_security"

echo ""
echo "=== T18: exit_code_always_zero ==="
run_cli "t18a" "missing-state-sid" "" ""
assert_exit "T18a. exit 0 (T3 case: no state)" "0"

T18B_JSON=$(build_state_json "sid-t18b" "clarify_intent")
run_cli "t18b" "sid-t18b" "$T18B_JSON" ""
assert_exit "T18b. exit 0 (T5 case: skill)" "0"

T18C_JSON=$(build_state_json "sid-t18c" "user_verification")
run_cli "t18c" "sid-t18c" "$T18C_JSON" ""
assert_exit "T18c. exit 0 (T12 case: sentinel-wait)" "0"

echo ""
echo "=== T19: exit_code_unknown_flag ==="
run_cli "t19" "" "" "" "--bogus-flag"
assert_exit "T19. exit 1 for unknown flag" "1"
assert_stderr_contains "T19. stderr mentions unknown flag" "nknown"

echo ""
echo "=== T20: exit_code_help ==="
run_cli "t20" "" "" "" "--help"
assert_exit "T20. exit 0 for --help" "0"
assert_stdout_contains "T20. stdout contains Usage" "Usage"
