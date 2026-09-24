# c-round-trip.sh - section C: OFF sentinel -> marker -> isWorkflowOff round
# trip (test_C1-test_C3).
# Sourced by tests/feature-workflow-off-session-override.sh; expects helpers.sh
# already sourced.

# ============================================================================
# C. Round-trip — OFF sentinel → marker → isWorkflowOff returns true
# ============================================================================

test_C1_round_trip_off_creates_and_off_returns_true() {
    require_mark_js "C1" || return
    require_session_markers_js "C1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: C1 round trip>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ ! -f "$wfdir/$sid.workflow-off" ]; then
        fail "C1: marker NOT created in round trip (out: $MARK_OUT)"
        return
    fi
    local out; out="$(run_is_workflow_off "$wfdir" '"abc123"')"
    if echo "$out" | grep -qx "true"; then
        pass "C1: OFF sentinel → marker → isWorkflowOff returns true"
    else
        fail "C1: round trip — expected 'true' but got: $out"
    fi
}

test_C2_marker_removal_returns_false() {
    require_session_markers_js "C2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    write_marker_file "$wfdir" "$sid"
    rm -f "$wfdir/$sid.workflow-off"
    local out; out="$(run_is_workflow_off "$wfdir" '"abc123"')"
    if echo "$out" | grep -qx "false"; then
        pass "C2: marker removed → isWorkflowOff returns false"
    else
        fail "C2: expected 'false' after marker removal but got: $out"
    fi
}

test_C3_off_on_round_trip_via_sentinels() {
    require_mark_js "C3" || return
    require_session_markers_js "C3" || return
    # OFF sentinel creates the marker, then ON sentinel deletes it.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"

    # Step 1: OFF sentinel creates marker.
    local off_payload; off_payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: C3 step1>>"' 0)"
    run_workflow_mark "$off_payload" "$wfdir"
    if [ ! -f "$wfdir/$sid.workflow-off" ]; then
        fail "C3 step1: OFF sentinel did not create marker (out: $MARK_OUT)"
        return
    fi

    # Step 2: isWorkflowOff returns true.
    local out_on; out_on="$(run_is_workflow_off "$wfdir" '"abc123"')"
    if ! echo "$out_on" | grep -qx "true"; then
        fail "C3 step2: isWorkflowOff returned non-true: $out_on"
        return
    fi

    # Step 3: ON sentinel deletes the marker.
    local on_payload; on_payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: C3 step3>>"' 0)"
    run_workflow_mark "$on_payload" "$wfdir"
    if [ -f "$wfdir/$sid.workflow-off" ]; then
        fail "C3 step3: ON sentinel did not delete marker (out: $MARK_OUT)"
        return
    fi

    # Step 4: isWorkflowOff returns false again.
    local out_off; out_off="$(run_is_workflow_off "$wfdir" '"abc123"')"
    if echo "$out_off" | grep -qx "false"; then
        pass "C3: OFF → ON round trip — isWorkflowOff returns false after ON"
    else
        fail "C3: expected 'false' after ON sentinel but got: $out_off"
    fi
}

