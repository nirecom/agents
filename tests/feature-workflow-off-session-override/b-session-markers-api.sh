# b-session-markers-api.sh - section B: hooks/lib/session-markers.js direct
# API (test_B1-test_B7).
# Sourced by tests/feature-workflow-off-session-override.sh; expects helpers.sh
# (pass/fail, SESSION_MARKERS_JS, require_session_markers_js,
# run_is_workflow_off, run_notice_text, write_marker_file) already sourced.

# ============================================================================
# B. hooks/lib/session-markers.js direct API
# ============================================================================

test_B1_isworkflowoff_true_when_marker_exists() {
    require_session_markers_js "B1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    write_marker_file "$wfdir" "$sid"
    local out; out="$(run_is_workflow_off "$wfdir" '"abc123"')"
    if echo "$out" | grep -qx "true"; then
        pass "B1: isWorkflowOff(sid) returns true when marker file exists"
    else
        fail "B1: expected 'true' but got: $out"
    fi
}

test_B2_isworkflowoff_false_when_no_marker() {
    require_session_markers_js "B2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local out; out="$(run_is_workflow_off "$wfdir" '"abc123"')"
    if echo "$out" | grep -qx "false"; then
        pass "B2: isWorkflowOff(sid) returns false when marker absent"
    else
        fail "B2: expected 'false' but got: $out"
    fi
}

test_B3_isworkflowoff_wrong_sid_returns_false() {
    require_session_markers_js "B3" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    write_marker_file "$wfdir" "session-A"
    # Calling with a different sid → marker file mismatch → false.
    local out; out="$(run_is_workflow_off "$wfdir" '"session-B"')"
    if echo "$out" | grep -qx "false"; then
        pass "B3: wrong sid → isWorkflowOff returns false"
    else
        fail "B3: expected 'false' but got: $out"
    fi
}

test_B4_isworkflowoff_empty_sid_returns_false() {
    require_session_markers_js "B4" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local out; out="$(run_is_workflow_off "$wfdir" '""')"
    # Empty string sid does not match [A-Za-z0-9_-]+ → fail-closed → false.
    if echo "$out" | grep -qx "false"; then
        pass "B4: empty-string sid → isWorkflowOff returns false"
    else
        fail "B4: expected 'false' but got: $out"
    fi
}

test_B5_isworkflowoff_traversal_sid_returns_false() {
    require_session_markers_js "B5" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # Plant a marker outside wfdir to ensure traversal would succeed if not validated.
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/foo.workflow-off"
    local out; out="$(run_is_workflow_off "$wfdir" '"../foo"')"
    rm -f "$parent/foo.workflow-off" 2>/dev/null || true
    if echo "$out" | grep -qx "false"; then
        pass "B5: path-traversal sid → isWorkflowOff returns false (validated)"
    else
        fail "B5: expected 'false' but got: $out"
    fi
}

test_B6_isworkflowoff_failclosed_when_getworkflowdir_throws() {
    require_session_markers_js "B6" || return
    # Without CLAUDE_WORKFLOW_DIR / HOME / USERPROFILE, getWorkflowDir() should
    # throw or yield an unusable path. isWorkflowOff must fail-closed (false)
    # rather than propagating the exception.
    local out; out="$(run_is_workflow_off "" '"abc123"')"
    if echo "$out" | grep -q "THREW:"; then
        fail "B6: isWorkflowOff propagated exception (must fail-closed): $out"
        return
    fi
    if echo "$out" | grep -qx "false"; then
        pass "B6: getWorkflowDir() unusable → isWorkflowOff returns false (fail-closed)"
    else
        fail "B6: expected 'false' but got: $out"
    fi
}

test_B7_notice_text_never_throws() {
    require_session_markers_js "B7" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # Call without writing any marker file. workflowOffNoticeText must still
    # produce a string without throwing.
    local out; out="$(run_notice_text "$wfdir" '"enforce-worktree"' '"abc123"')"
    if echo "$out" | grep -q "THREW:"; then
        fail "B7: workflowOffNoticeText threw an exception: $out"
        return
    fi
    if ! echo "$out" | grep -q "^TYPE:string"; then
        fail "B7: workflowOffNoticeText did not return a string (out: $out)"
        return
    fi
    pass "B7: workflowOffNoticeText(hookName, sid) returns string without throwing"
}

