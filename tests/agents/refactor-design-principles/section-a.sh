# section-a.sh — Section A: USER_VERIFIED sentinel tests
# Sourced by tests/refactor-design-principles.sh after helpers.sh.

test_A1_bare_user_verified_rejected_as_malformed() {
    require_mark_js "A1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession1"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_USER_VERIFIED>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"

    # Bare form must be rejected — user_verification must remain pending (NOT complete)
    local status; status="$(read_uv_status "$wfdir" "$sid")"
    if [ "$status" = "complete" ]; then
        fail "A1: bare USER_VERIFIED was accepted (status=complete, expected pending) (out: $MARK_OUT)"
        return
    fi

    # Must emit a "malformed USER_VERIFIED" error (case-insensitive)
    if ! echo "$MARK_OUT" | grep -qi "malformed USER_VERIFIED"; then
        fail "A1: expected 'malformed USER_VERIFIED' in output (out: $MARK_OUT)"
        return
    fi

    pass "A1: bare USER_VERIFIED rejected as malformed — status remains pending"
}

test_A2_valid_reason_records_without_warn() {
    require_mark_js "A2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession2"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_USER_VERIFIED: merging PR 12>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"

    # user_verification must be recorded as complete
    local status; status="$(read_uv_status "$wfdir" "$sid")"
    if [ "$status" != "complete" ]; then
        fail "A2: user_verification not recorded as complete (status='$status', out: $MARK_OUT)"
        return
    fi

    # Must NOT emit the "without reason" warning
    if echo "$MARK_OUT" | grep -q "emitted without reason"; then
        fail "A2: unexpected 'emitted without reason' warning for valid reason (out: $MARK_OUT)"
        return
    fi

    # Must NOT emit "reason rejected"
    if echo "$MARK_OUT" | grep -q "reason rejected"; then
        fail "A2: unexpected 'reason rejected' for valid reason (out: $MARK_OUT)"
        return
    fi

    pass "A2: valid reason USER_VERIFIED — recorded as complete, no warnings"
}

test_A3_short_reason_records_and_warns() {
    require_mark_js "A3" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession3"
    # "no" is only 2 non-space chars — too short
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_USER_VERIFIED: no>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"

    # user_verification must STILL be recorded despite bad reason
    local status; status="$(read_uv_status "$wfdir" "$sid")"
    if [ "$status" != "complete" ]; then
        fail "A3: user_verification not recorded as complete despite bad reason (status='$status', out: $MARK_OUT)"
        return
    fi

    # Must emit "reason rejected"
    if ! echo "$MARK_OUT" | grep -q "USER_VERIFIED reason rejected"; then
        fail "A3: expected 'USER_VERIFIED reason rejected' in output (out: $MARK_OUT)"
        return
    fi

    pass "A3: too-short reason — warn but apply (soft-validation tradeoff) + reason-rejected warning"
}

test_A4_no_session_id_not_recorded() {
    require_mark_js "A4" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local payload; payload="$(build_mark_payload_no_sid 'echo "<<WORKFLOW_USER_VERIFIED: no session id branch>>"' 0)"
    local rc=0
    # Block all resolveSessionId fallback paths:
    #   P2: unset CLAUDE_CODE_SESSION_ID
    #   P4: unset CLAUDE_SESSION_ID
    #   P6: run node from TMPDIR_BASE (no WORKTREE_NOTES.md there)
    #   P7: point CLAUDE_TRANSCRIPT_BASE_DIR at an empty dir (no JSONL files)
    local _mark_js="$MARK_JS" _agents_dir="$AGENTS_DIR" _tmpbase="$TMPDIR_BASE"
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        -u CLAUDE_CODE_SESSION_ID \
        -u CLAUDE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$_agents_dir" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_TRANSCRIPT_BASE_DIR=$_tmpbase/no-transcripts" \
        bash -c 'cd "$1" && node "$2"' -- "$_tmpbase" "$_mark_js" 2>&1)" || rc=$?

    # Must emit "could not resolve session_id" — check this first
    if ! echo "$MARK_OUT" | grep -q "could not resolve session_id"; then
        fail "A4: expected 'could not resolve session_id' in output (rc=$rc, out: $MARK_OUT)"
        return
    fi

    # rc=2 is the expected exit when session_id is unresolvable (not a crash).
    # Any other non-zero exit is unexpected.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        fail "A4: workflow-mark.js unexpected exit rc=$rc (out: $MARK_OUT)"
        return
    fi

    # user_verification must not be recorded as complete (even if .json exists)
    local any_complete=0
    for f in "$wfdir"/*.json; do
        [ -f "$f" ] || continue
        local s; s="$(node -e "
try {
  const st=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  console.log((st.steps&&st.steps.user_verification&&st.steps.user_verification.status)||'');
} catch(e){console.log('');}
" "$f" 2>/dev/null)"
        if [ "$s" = "complete" ]; then
            any_complete=1
            break
        fi
    done
    if [ "$any_complete" -eq 1 ]; then
        fail "A4: user_verification recorded as complete without session_id (out: $MARK_OUT)"
        return
    fi

    pass "A4: no session_id — user_verification NOT recorded, session_id warning emitted"
}
