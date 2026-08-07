# sec-path-traversal.sh - section SEC: path traversal / metachar protection
# (workflow-mark.js), plus its own marker-scanning helpers (test_SEC1-test_SEC3).
# Sourced by tests/feature-workflow-off-session-override.sh; expects helpers.sh
# already sourced.

# ============================================================================
# SEC. Path traversal / metachar protection (workflow-mark.js)
# ============================================================================

# Helper: count *.workflow-off files anywhere under a directory (incl. parent
# escapes). We look for any leftover marker that would prove the guard failed
# to reject a malicious session ID.
count_workflow_off_files() {
    local root="$1"
    # Search ABOVE root too — `../evil.workflow-off` would land in the parent dir.
    local parent; parent="$(dirname "$root")"
    find "$parent" -maxdepth 3 -name '*.workflow-off' 2>/dev/null | wc -l | tr -d ' '
}

# Assert that no *.workflow-off file under `root` (searched the same way as
# count_workflow_off_files, i.e. including the parent dir for traversal
# escapes) carries a filename derived from `needle` (the malicious/malformed
# session id under test). Echoes 1 (found — bad) or 0 (clean) on stdout.
grep_marker_names_for_needle() {
    local root="$1" needle="$2"
    local parent; parent="$(dirname "$root")"
    find "$parent" -maxdepth 3 -name '*.workflow-off' 2>/dev/null \
        | grep -F -- "$needle" | wc -l | tr -d ' '
}

# SEC1 contract (post-#1794 resolveSessionId change, see hooks/workflow-state/session-id.js):
# a tier-1-invalid session_id (e.g. path traversal) is no longer forced into a
# hard-block at the point of resolution — resolveSessionId() rejects it at
# tier 1 and falls through to later fallback tiers. Only if NO tier resolves a
# usable id does workflow-mark.js hard-block. This test uses
# run_workflow_mark_isolated so that no fallback tier CAN resolve an id,
# reproducing the same "no session_id resolvable" outcome as test_A5 — see
# that test for the reference rc/message contract. The invariant this test
# actually protects is: the malicious string must never appear in a marker
# filename, anywhere (including a parent-directory escape), regardless of rc.
test_SEC1_path_traversal_rejected() {
    require_mark_js "SEC1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local before_count after_count
    before_count="$(count_workflow_off_files "$wfdir")"
    local payload; payload="$(build_mark_payload "../evil" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: SEC1 traversal>>"' 0)"
    local rc=0
    run_workflow_mark_isolated "$payload" "$wfdir" || rc=$?
    after_count="$(count_workflow_off_files "$wfdir")"
    # No fallback tier can resolve an id (isolated env+cwd) → same outcome as
    # test_A5_no_session_id_hard_blocks: hard-block rc=2, diagnostic mentions
    # session/resolve, no marker written at all.
    if [ "$rc" -ne 2 ]; then
        fail "SEC1: expected the same 'no session_id resolvable' hard-block (rc=2) as A5, got rc=$rc (out: $MARK_OUT)"
        return
    fi
    if [ "$after_count" != "$before_count" ]; then
        fail "SEC1: traversal session ID produced a marker file (count $before_count -> $after_count, out: $MARK_OUT)"
        return
    fi
    if [ "$(grep_marker_names_for_needle "$wfdir" "evil")" != "0" ]; then
        fail "SEC1: '../evil' string leaked into a marker filename (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qiE "session(_id)?|resolve"; then
        fail "SEC1: stderr missing 'session'/'resolve' diagnostic (out: $MARK_OUT)"
        return
    fi
    pass "SEC1: ../evil session ID never reaches a marker filename — resolves to A5's no-session-id hard-block (rc=2)"
}

# SEC2 contract: same reasoning as SEC1 above, applied to a set of shell-
# metacharacter / malformed session ids. With run_workflow_mark_isolated, none
# of them can be resolved by any fallback tier, so each reproduces A5's "no
# session_id resolvable" hard-block (rc=2). The invariant under test is that
# none of these strings ever appear in a written marker filename and the hook
# never crashes.
test_SEC2_shell_metachars_rejected() {
    require_mark_js "SEC2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # Several attempts; each must NOT produce a marker, and the hook must not crash.
    local payloads_sid=( '$(rm)' 'a/b' 'a\\b' 'a b' )
    local sid before_count after_count rc
    local any_failure=0
    for sid in "${payloads_sid[@]}"; do
        before_count="$(count_workflow_off_files "$wfdir")"
        local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: SEC2 metachars>>"' 0)"
        rc=0
        run_workflow_mark_isolated "$payload" "$wfdir" || rc=$?
        after_count="$(count_workflow_off_files "$wfdir")"
        # Same "no session_id resolvable" outcome as A5 (isolated: no fallback
        # tier can resolve an id) — hard-block rc=2.
        if [ "$rc" -ne 2 ]; then
            fail "SEC2: expected the same 'no session_id resolvable' hard-block (rc=2) as A5 for session ID '$sid', got rc=$rc (out: $MARK_OUT)"
            any_failure=1
            continue
        fi
        if [ "$after_count" != "$before_count" ]; then
            fail "SEC2: marker created for malicious session ID '$sid' (count $before_count -> $after_count)"
            any_failure=1
        fi
    done
    if [ "$any_failure" = "0" ]; then
        pass "SEC2: all shell-metachar session IDs never reach a marker filename — resolve to A5's no-session-id hard-block (rc=2), no crashes"
    fi
}

test_SEC3_env_file_traversal_failclosed() {
    require_session_markers_js "SEC3" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # Plant a marker at the traversal path so a faulty bypass would be detected
    # as `isWorkflowOff` returning true.
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/passwd.workflow-off"
    # Use isWorkflowOff with a traversal sid passed directly. The module must
    # validate the sid against [A-Za-z0-9_-]+ and fail-closed (return false)
    # regardless of any planted file outside wfdir.
    local out; out="$(run_is_workflow_off "$wfdir" '"../passwd"')"
    rm -f "$parent/passwd.workflow-off" 2>/dev/null || true
    if echo "$out" | grep -q "THREW:"; then
        fail "SEC3: isWorkflowOff threw on traversal sid (must fail-closed): $out"
        return
    fi
    if echo "$out" | grep -qx "false"; then
        pass "SEC3: traversal sid → isWorkflowOff fail-closed (false)"
    else
        fail "SEC3: traversal sid bypass — expected 'false' but got: $out"
    fi
}

