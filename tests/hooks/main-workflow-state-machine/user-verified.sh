# shellcheck shell=bash
# Case group: Section 4 — USER_VERIFIED hook.
# Sourced by main-workflow-state-machine.sh; relies on helpers from common.sh.

run_user_verified_tests() {
    # ---------------------------------------------------------------------------
    # Section 4: USER_VERIFIED hook
    # ---------------------------------------------------------------------------
    echo ""
    echo "=== Section 4: USER_VERIFIED ==="

    REPO_4=$(setup_repo)

    # L4-a: WORKFLOW_USER_VERIFIED → user_verification=complete
    SID_4A="l4a-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_4A" "$(ALL_PENDING_JSON "$SID_4A")"
    run_mark_hook "$REPO_4" "$(build_mark_json 'echo "<<WORKFLOW_USER_VERIFIED: L4-a state test>>"' "$SID_4A")" >/dev/null
    expect_state_step "L4-a. WORKFLOW_USER_VERIFIED → user_verification=complete" \
        "$SID_4A" "user_verification" "complete"

    # L4-b: MARK_STEP_user_verification_complete → (a) state unchanged (b) rejection msg (c) exit 0
    SID_4B="l4b-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_4B" "$(ALL_PENDING_JSON "$SID_4B")"
    L4B_CMD='echo "<<WORKFLOW_MARK_STEP_user_verification_complete>>"'
    L4B_ESC=${L4B_CMD//\"/\\\"}
    L4B_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"","stderr":""},"session_id":"%s"}' \
        "$L4B_ESC" "$SID_4B")
    L4B_EXIT=0
    L4B_OUT=$(echo "$L4B_JSON" | CLAUDE_PROJECT_DIR="$REPO_4" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        node "$MARK_HOOK" 2>/dev/null) || L4B_EXIT=$?
    if [ "$L4B_EXIT" = "0" ]; then
        pass "L4-b(exit). MARK_STEP_user_verification → exit 0"
    else
        fail "L4-b(exit). MARK_STEP_user_verification → expected exit 0, got $L4B_EXIT"
    fi
    expect_no_state_change "L4-b(state). MARK_STEP_user_verification → user_verification stays pending" \
        "$SID_4B" "user_verification" "pending"
    if echo "$L4B_OUT" | grep -qi "user_verification\|rejected\|additionalContext\|MARK_STEP"; then
        pass "L4-b(msg). MARK_STEP_user_verification → rejection message in output"
    else
        fail "L4-b(msg). MARK_STEP_user_verification → no rejection in output: $L4B_OUT"
    fi

    # L4-c: session_id missing → user_verification unchanged, exit 0
    SID_4C="l4c-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_4C" "$(ALL_PENDING_JSON "$SID_4C")"
    L4C_CMD='echo "<<WORKFLOW_USER_VERIFIED: L4-c no session id>>"'
    L4C_ESC=${L4C_CMD//\"/\\\"}
    L4C_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"","stderr":""}}' "$L4C_ESC")
    L4C_EXIT=0
    echo "$L4C_JSON" | CLAUDE_PROJECT_DIR="$REPO_4" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        env -u CLAUDE_ENV_FILE node "$MARK_HOOK" 2>/dev/null || L4C_EXIT=$?
    if [ "$L4C_EXIT" = "0" ]; then
        pass "L4-c(exit). no session_id + USER_VERIFIED → exit 0"
    else
        fail "L4-c(exit). no session_id + USER_VERIFIED → expected exit 0, got $L4C_EXIT"
    fi
    expect_no_state_change "L4-c(state). no session_id → user_verification stays pending" \
        "$SID_4C" "user_verification" "pending"
}
