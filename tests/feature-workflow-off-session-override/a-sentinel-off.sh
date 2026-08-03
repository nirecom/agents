# a-sentinel-off.sh - section A: sentinel ingestion (workflow-mark.js) OFF/ON,
# bare-form rejection, and transcript_path fallback (test_A1-test_A15).
# Sourced by tests/feature-workflow-off-session-override.sh; expects helpers.sh
# (pass/fail, MARK_JS, require_mark_js, build_mark_payload*, write_marker_file,
# run_workflow_mark*, fresh_workflow_dir) already sourced.

# ============================================================================
# A. Sentinel ingestion (workflow-mark.js) — OFF
# ============================================================================

test_A1_marker_created_on_sentinel() {
    require_mark_js "A1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A1 marker test>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ -f "$wfdir/$sid.workflow-off" ]; then
        pass "A1: marker file created for valid sentinel"
    else
        fail "A1: marker NOT created (out: $MARK_OUT)"
    fi
}

test_A2_marker_with_reason() {
    require_mark_js "A2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: maintenance recovery>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    local mfile="$wfdir/$sid.workflow-off"
    if [ ! -f "$mfile" ]; then
        fail "A2: marker NOT created for sentinel with reason (out: $MARK_OUT)"
        return
    fi
    local content; content="$(cat "$mfile")"
    if echo "$content" | grep -q '"reason"' \
       && echo "$content" | grep -q 'maintenance recovery' \
       && echo "$content" | grep -q '"set_at"'; then
        pass "A2: marker JSON contains reason + set_at"
    else
        fail "A2: marker JSON missing reason/set_at fields (content: $content)"
    fi
}

test_A3_non_zero_exit_skips() {
    require_mark_js "A3" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A3 non-zero exit>>"' 1)"
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    if [ -f "$wfdir/$sid.workflow-off" ]; then
        fail "A3: marker should NOT exist when echo exit_code=1 (out: $MARK_OUT)"
        return
    fi
    if [ "$rc" -ne 0 ]; then
        fail "A3: workflow-mark.js crashed with rc=$rc on non-zero exit (out: $MARK_OUT)"
        return
    fi
    pass "A3: non-zero exit_code → no marker, hook exits 0"
}

test_A4_env_file_fallback() {
    require_mark_js "A4" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="xyz"
    local envfile; envfile="$(setup_fake_env_file "$sid")"
    local payload; payload="$(build_mark_payload_no_sid 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A4 env-file fallback>>"' 0)"
    # Note: run_workflow_mark unsets CLAUDE_ENV_FILE; pass it explicitly here.
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$FIXTURE_PLANS_DIR" \
        "CLAUDE_ENV_FILE=$envfile" \
        node "$MARK_JS" 2>&1)" || true
    if [ -f "$wfdir/$sid.workflow-off" ]; then
        pass "A4: env-file fallback resolves session ID"
    else
        fail "A4: env-file fallback did not create marker (out: $MARK_OUT)"
    fi
}

test_A5_no_session_id_hard_blocks() {
    require_mark_js "A5" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local payload; payload="$(build_mark_payload_no_sid 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A5 no session id>>"' 0)"
    local rc=0
    # No CLAUDE_ENV_FILE → no session ID resolvable. Must hard-block (rc=2).
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$FIXTURE_PLANS_DIR" \
        node "$MARK_JS" 2>&1)" || rc=$?
    # No marker should be written.
    local count
    count="$(ls -1 "$wfdir" 2>/dev/null | grep -c '\.workflow-off$' || true)"
    if [ "$count" -ne 0 ]; then
        fail "A5: marker created without session_id (count=$count, out: $MARK_OUT)"
        return
    fi
    if [ "$rc" -ne 2 ]; then
        fail "A5: expected hard-block rc=2 but got rc=$rc (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qiE "session(_id)?|resolve"; then
        fail "A5: stderr missing 'session'/'resolve' diagnostic (out: $MARK_OUT)"
        return
    fi
    pass "A5: missing session_id → hard-block rc=2, no marker, diagnostic surfaced"
}

test_A6_chained_sentinels_accepted() {
    require_mark_js "A6" || return
    # workflow-mark.js splits on `&&` and requires every part to be a recognised
    # sentinel. Because WORKFLOW_ENFORCE_WORKFLOW_OFF is part of isSentinel(),
    # chaining it with another valid sentinel (USER_VERIFIED) must succeed: the
    # marker is created alongside the chained sentinel's effects.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local cmd='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A6 chain test>>" && echo "<<WORKFLOW_USER_VERIFIED: A6 chain test>>"'
    local payload; payload="$(build_mark_payload "$sid" "$cmd" 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ -f "$wfdir/$sid.workflow-off" ]; then
        pass "A6: chained sentinels processed — marker created alongside USER_VERIFIED"
    else
        fail "A6: chained sentinel rejected — marker NOT created (out: $MARK_OUT)"
    fi
}

test_A7_idempotent_marker_write() {
    require_mark_js "A7" || return
    # Running the sentinel twice should produce a stable marker file — no crash,
    # no leftover .tmp file, and the second write overwrites cleanly (atomic
    # tmp+rename pattern).
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A7 idempotent write>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    run_workflow_mark "$payload" "$wfdir"
    local marker="$wfdir/$sid.workflow-off"
    # No stale .tmp files.
    local tmp_count; tmp_count="$(find "$wfdir" -name '*.workflow-off.tmp' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$tmp_count" -ne 0 ]; then
        fail "A7: stale .tmp file left after double-write (out: $MARK_OUT)"
        return
    fi
    if [ -f "$marker" ]; then
        pass "A7: idempotent double-write — marker present, no .tmp residue"
    else
        fail "A7: marker NOT created after double sentinel invocation (out: $MARK_OUT)"
    fi
}

# ----------------------------------------------------------------------------
# A8-A11: WORKFLOW_ENFORCE_WORKFLOW_ON sentinel — restores enforcement by
# deleting the per-session marker.
# ----------------------------------------------------------------------------

test_A8_on_sentinel_deletes_marker() {
    require_mark_js "A8" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    # Pre-existing marker (e.g. set earlier in the session via OFF sentinel).
    write_marker_file "$wfdir" "$sid"
    [ -f "$wfdir/$sid.workflow-off" ] || { fail "A8 setup: marker not written"; return; }
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: A8 delete marker>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ ! -f "$wfdir/$sid.workflow-off" ]; then
        pass "A8: ON sentinel deleted the existing marker"
    else
        fail "A8: marker still present after ON sentinel (out: $MARK_OUT)"
    fi
}

test_A9_on_sentinel_no_marker_idempotent() {
    require_mark_js "A9" || return
    # ON sentinel with no existing marker must be a silent no-op (idempotent).
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: A9 idempotent on>>"' 0)"
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "A9: ON sentinel with no marker crashed rc=$rc (out: $MARK_OUT)"
        return
    fi
    if [ -f "$wfdir/$sid.workflow-off" ]; then
        fail "A9: ON sentinel created a marker (should be no-op, out: $MARK_OUT)"
        return
    fi
    pass "A9: ON sentinel with no existing marker — silent no-op"
}

test_A10_on_sentinel_no_session_id() {
    require_mark_js "A10" || return
    # No session_id, no CLAUDE_ENV_FILE → must hard-block (rc=2), preserve any
    # pre-existing unrelated marker (cross-session isolation), and emit a
    # diagnostic mentioning session resolution failure.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    write_marker_file "$wfdir" "someone-else"
    local payload
    payload='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: A10 no session id>>\""}, "tool_response":{"exit_code":0}}'
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    if [ "$rc" -ne 2 ]; then
        fail "A10: expected hard-block rc=2 but got rc=$rc (out: $MARK_OUT)"
        return
    fi
    # Other-session marker MUST still exist (no cross-session deletion).
    if [ ! -f "$wfdir/someone-else.workflow-off" ]; then
        fail "A10: ON sentinel without session_id deleted unrelated marker (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qiE "session(_id)?|resolve"; then
        fail "A10: stderr missing 'session'/'resolve' diagnostic (out: $MARK_OUT)"
        return
    fi
    pass "A10: no session_id → ON sentinel hard-blocks rc=2, cross-session isolation preserved"
}

test_A11_on_sentinel_session_isolation() {
    require_mark_js "A11" || return
    # ON sentinel must only delete the calling session's marker, not others'.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    write_marker_file "$wfdir" "session-A"
    write_marker_file "$wfdir" "session-B"
    local payload; payload="$(build_mark_payload "session-A" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: A11 isolation>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ -f "$wfdir/session-A.workflow-off" ]; then
        fail "A11: session-A marker NOT deleted (out: $MARK_OUT)"
        return
    fi
    if [ ! -f "$wfdir/session-B.workflow-off" ]; then
        fail "A11: session-B marker incorrectly deleted (cross-session leak, out: $MARK_OUT)"
        return
    fi
    pass "A11: ON sentinel deletes only the calling session's marker"
}

# ----------------------------------------------------------------------------
# A12-A13: Bare-form rejection.
# Bare WORKFLOW_ENFORCE_WORKFLOW_OFF / _ON must be rejected as malformed —
# no marker mutation, error surfaced.
# ----------------------------------------------------------------------------

test_A12_bare_off_malformed() {
    require_mark_js "A12" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ -f "$wfdir/$sid.workflow-off" ]; then
        fail "A12: bare OFF was accepted — marker created (expected rejection) (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qi "malformed"; then
        fail "A12: bare OFF — expected 'malformed' in output (out: $MARK_OUT)"
        return
    fi
    pass "A12: bare ENFORCE_WORKFLOW_OFF rejected as malformed — no marker"
}

test_A13_bare_on_malformed() {
    require_mark_js "A13" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    # Pre-existing marker — bare ON must NOT delete it.
    write_marker_file "$wfdir" "$sid"
    [ -f "$wfdir/$sid.workflow-off" ] || { fail "A13 setup: marker not written"; return; }
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ ! -f "$wfdir/$sid.workflow-off" ]; then
        fail "A13: bare ON was accepted — marker deleted (expected preservation) (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qi "malformed"; then
        fail "A13: bare ON — expected 'malformed' in output (out: $MARK_OUT)"
        return
    fi
    pass "A13: bare ENFORCE_WORKFLOW_ON rejected as malformed — marker preserved"
}

# ----------------------------------------------------------------------------
# A14-A15: transcript_path fallback (#461)
# When session_id is absent from input AND CLAUDE_ENV_FILE is unset,
# workflow-mark.js must fall back to deriving the session ID from
# transcript_path (basename without .jsonl). Path must be validated.
# ----------------------------------------------------------------------------

test_A14_transcript_path_fallback() {
    require_mark_js "A14" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # Fixed UUID-like filename so the expected marker name is predictable.
    # The file does NOT need to exist — only the path basename matters.
    local sid="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    local tp="$TMPDIR_BASE/projects/foo/${sid}.jsonl"
    local payload; payload="$(build_mark_payload_with_transcript 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A14 transcript fallback>>"' 0 "$tp")"
    local rc=0
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$FIXTURE_PLANS_DIR" \
        node "$MARK_JS" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "A14: hook crashed with rc=$rc on transcript fallback (out: $MARK_OUT)"
        return
    fi
    if [ ! -f "$wfdir/$sid.workflow-off" ]; then
        fail "A14: transcript fallback did not create marker for sid='$sid' (out: $MARK_OUT)"
        return
    fi
    pass "A14: transcript_path fallback → session ID derived → marker created"
}

test_A15_transcript_path_invalid_chars() {
    require_mark_js "A15" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # transcript_path basename contains an invalid char (@) — must be rejected, no marker, hard-block.
    local tp="$TMPDIR_BASE/abc@def.jsonl"
    local payload; payload="$(build_mark_payload_with_transcript 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A15 invalid chars>>"' 0 "$tp")"
    local rc=0
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$FIXTURE_PLANS_DIR" \
        node "$MARK_JS" 2>&1)" || rc=$?
    if [ "$rc" -ne 2 ]; then
        fail "A15: expected hard-block rc=2 but got rc=$rc (out: $MARK_OUT)"
        return
    fi
    local count
    count="$(ls -1 "$wfdir" 2>/dev/null | grep -c '\.workflow-off$' || true)"
    if [ "$count" -ne 0 ]; then
        fail "A15: marker created from invalid transcript_path (count=$count, out: $MARK_OUT)"
        return
    fi
    pass "A15: transcript_path with invalid basename chars rejected — hard-block, no marker"
}
