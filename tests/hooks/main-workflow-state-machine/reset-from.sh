# shellcheck shell=bash
# Case group: Section 3 — RESET_FROM hook.
# Sourced by main-workflow-state-machine.sh; relies on helpers from common.sh.

run_reset_from_tests() {
    # ---------------------------------------------------------------------------
    # Section 3: RESET_FROM hook
    # ---------------------------------------------------------------------------
    echo ""
    echo "=== Section 3: RESET_FROM ==="

    REPO_3=$(setup_repo)

    # L3-a: RESET_FROM_write_tests → steps before write_tests=complete, from write_tests=pending
    SID_3A="l3a-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_3A" "$(ALL_COMPLETE_JSON "$SID_3A")"
    run_mark_hook "$REPO_3" "$(build_mark_json 'echo "<<WORKFLOW_RESET_FROM_write_tests: test reason>>"' "$SID_3A")" >/dev/null
    expect_state_step "L3-a(research). RESET_FROM_write_tests → research=complete" \
        "$SID_3A" "research" "complete"
    expect_state_step "L3-a(outline). RESET_FROM_write_tests → outline=complete" \
        "$SID_3A" "outline" "complete"
    expect_state_step "L3-a(detail). RESET_FROM_write_tests → detail=complete" \
        "$SID_3A" "detail" "complete"
    expect_state_step "L3-a(write_tests). RESET_FROM_write_tests → write_tests=pending" \
        "$SID_3A" "write_tests" "pending"
    expect_state_step "L3-a(user_verification). RESET_FROM_write_tests → user_verification=pending" \
        "$SID_3A" "user_verification" "pending"

    # L3-b: RESET_FROM_research → all steps=pending
    SID_3B="l3b-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_3B" "$(ALL_COMPLETE_JSON "$SID_3B")"
    run_mark_hook "$REPO_3" "$(build_mark_json 'echo "<<WORKFLOW_RESET_FROM_research: test reason>>"' "$SID_3B")" >/dev/null
    expect_state_step "L3-b(research). RESET_FROM_research → research=pending" \
        "$SID_3B" "research" "pending"
    expect_state_step "L3-b(user_verification). RESET_FROM_research → user_verification=pending" \
        "$SID_3B" "user_verification" "pending"

    # L3-c: RESET_FROM_foo (unknown step) → state unchanged, ignored
    SID_3C="l3c-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_3C" "$(ALL_COMPLETE_JSON "$SID_3C")"
    run_mark_hook "$REPO_3" "$(build_mark_json 'echo "<<WORKFLOW_RESET_FROM_foo: test reason>>"' "$SID_3C")" >/dev/null
    expect_state_step "L3-c. RESET_FROM_foo (unknown) → research stays complete" \
        "$SID_3C" "research" "complete"

    # L3-d: session_id missing → state unchanged, exit 0, additionalContext warning
    SID_3D="l3d-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_3D" "$(ALL_COMPLETE_JSON "$SID_3D")"
    L3D_CMD='echo "<<WORKFLOW_RESET_FROM_write_tests: test reason>>"'
    L3D_ESC=${L3D_CMD//\"/\\\"}
    L3D_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"","stderr":""}}' "$L3D_ESC")
    L3D_EXIT=0
    L3D_OUT=$(echo "$L3D_JSON" | CLAUDE_PROJECT_DIR="$REPO_3" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        env -u CLAUDE_ENV_FILE node "$MARK_HOOK" 2>/dev/null) || L3D_EXIT=$?
    if [ "$L3D_EXIT" = "0" ]; then
        pass "L3-d(exit). session_id missing + RESET_FROM → exit 0"
    else
        fail "L3-d(exit). expected exit 0, got $L3D_EXIT"
    fi
    expect_state_step "L3-d(state). session_id missing → research stays complete" \
        "$SID_3D" "research" "complete"
    if echo "$L3D_OUT" | grep -qi "additionalContext\|session_id\|re-run"; then
        pass "L3-d(msg). session_id missing → warning in additionalContext output"
    else
        fail "L3-d(msg). session_id missing → no warning in output: $L3D_OUT"
    fi
}
