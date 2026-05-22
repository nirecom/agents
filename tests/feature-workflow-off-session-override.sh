#!/bin/bash
# tests/feature-workflow-off-session-override.sh
#
# Integration tests for the session-scoped ENFORCE_WORKFLOW escape hatch.
#
# Feature contract:
#   - workflow-mark.js (PostToolUse) intercepts:
#       echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>"
#     and writes a marker file:
#       <workflowDir>/<sessionId>.workflow-off
#     The marker JSON contains "set_at" and (optionally) "reason".
#   - hooks/lib/session-markers.js exports isWorkflowOff(sid) which returns
#     true iff <workflowDir>/<sid>.workflow-off exists and sid is well-formed.
#     Fail-closed on any error.
#   - The matching ON sentinel:
#       echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: <reason>>"
#     deletes the marker (per-session only).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MARK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-mark.js"
SESSION_MARKERS_JS="${_AGENTS_DIR_NODE}/hooks/lib/session-markers.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eworkflow-sess-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Portable timeout: prefers `timeout`, falls back to perl alarm (macOS-safe).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_mark_js() {
    if [ ! -f "$MARK_JS" ]; then
        fail "$1 (workflow-mark.js not present)"
        return 1
    fi
    return 0
}

require_session_markers_js() {
    if [ ! -f "$SESSION_MARKERS_JS" ]; then
        fail "$1 (hooks/lib/session-markers.js not present)"
        return 1
    fi
    return 0
}

# Allocate a fresh per-test workflow dir (so markers don't leak across tests).
fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# Write an env-file for CLAUDE_ENV_FILE-based session resolution.
# Usage: setup_fake_env_file <session-id>  → echoes the path of the env file.
setup_fake_env_file() {
    local sid="$1"
    local f="$TMPDIR_BASE/envfile-$RANDOM-$$"
    printf 'CLAUDE_SESSION_ID=%s\n' "$sid" > "$f"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$f"
    else
        echo "$f"
    fi
}

MARK_OUT=""
# run_workflow_mark <stdin-json> <workflow-dir> [extra env var ...]
# Returns workflow-mark.js exit code; captures stdout+stderr into MARK_OUT.
run_workflow_mark() {
    local payload="$1"; shift
    local wfdir="$1"; shift
    local rc=0
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "$@" \
        node "$MARK_JS" 2>&1)" || rc=$?
    return $rc
}

# JSON-safely pack a string as a JSON-encoded literal (via node).
json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Build a PostToolUse Bash payload for workflow-mark.js.
# Args: session-id command-string exit-code
build_mark_payload() {
    local sid="$1" cmd="$2" rc="$3"
    local q_sid q_cmd
    q_sid="$(json_quote "$sid")"
    q_cmd="$(json_quote "$cmd")"
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":"","stderr":""}}' \
        "$q_sid" "$q_cmd" "$rc"
}

# Same but with session_id omitted entirely (env-file fallback test).
build_mark_payload_no_sid() {
    local cmd="$1" rc="$2"
    local q_cmd
    q_cmd="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":"","stderr":""}}' \
        "$q_cmd" "$rc"
}

# Write a marker file directly (simulating a previous workflow-mark.js run).
# Args: workflow-dir session-id [reason]
write_marker_file() {
    local wfdir="$1" sid="$2" reason="${3:-}"
    if [ -n "$reason" ]; then
        printf '{"set_at":"2026-01-01T00:00:00Z","reason":"%s"}\n' "$reason" \
            > "$wfdir/$sid.workflow-off"
    else
        printf '{"set_at":"2026-01-01T00:00:00Z"}\n' \
            > "$wfdir/$sid.workflow-off"
    fi
}

# Invoke node with isWorkflowOff(sid) and echo the result ("true"/"false"/<error>).
# Args: <workflow-dir> <session-id-arg-as-js-literal>
# Note: <session-id-arg-as-js-literal> must be a node-syntax-valid expression
# (e.g. '"abc"' or '""' or '"../foo"'). When unset workflow dir is needed
# (for B6), pass empty string for wfdir.
run_is_workflow_off() {
    local wfdir="$1" sid_js="$2"
    local out rc=0
    if [ -n "$wfdir" ]; then
        out="$(run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            "CLAUDE_WORKFLOW_DIR=$wfdir" \
            node -e "const sm=require('$SESSION_MARKERS_JS'); try { console.log(sm.isWorkflowOff($sid_js)); } catch(e) { console.log('THREW:'+e.message); }" 2>&1)" || rc=$?
    else
        # No CLAUDE_WORKFLOW_DIR → getWorkflowDir() resolves a default which
        # may not be writable in CI; the test ensures fail-closed (no throw).
        out="$(run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE -u CLAUDE_WORKFLOW_DIR -u HOME -u USERPROFILE \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            node -e "const sm=require('$SESSION_MARKERS_JS'); try { console.log(sm.isWorkflowOff($sid_js)); } catch(e) { console.log('THREW:'+e.message); }" 2>&1)" || rc=$?
    fi
    printf '%s' "$out"
    return $rc
}

# Invoke node with workflowOffNoticeText(hookName, sid).
run_notice_text() {
    local wfdir="$1" hook_js="$2" sid_js="$3"
    local out rc=0
    out="$(run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node -e "const sm=require('$SESSION_MARKERS_JS'); try { const r = sm.workflowOffNoticeText($hook_js, $sid_js); console.log('TYPE:'+typeof r); console.log('VAL:'+r); } catch(e) { console.log('THREW:'+e.message); }" 2>&1)" || rc=$?
    printf '%s' "$out"
    return $rc
}

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
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile" \
        node "$MARK_JS" 2>&1)" || true
    if [ -f "$wfdir/$sid.workflow-off" ]; then
        pass "A4: env-file fallback resolves session ID"
    else
        fail "A4: env-file fallback did not create marker (out: $MARK_OUT)"
    fi
}

test_A5_no_session_id_no_crash() {
    require_mark_js "A5" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local payload; payload="$(build_mark_payload_no_sid 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: A5 no session id>>"' 0)"
    local rc=0
    # No CLAUDE_ENV_FILE → no session ID resolvable.
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$MARK_JS" 2>&1)" || rc=$?
    # No marker should be written.
    local count
    count="$(ls -1 "$wfdir" 2>/dev/null | grep -c '\.workflow-off$' || true)"
    if [ "$count" -ne 0 ]; then
        fail "A5: marker created without session_id (count=$count, out: $MARK_OUT)"
        return
    fi
    if [ "$rc" -ne 0 ]; then
        fail "A5: workflow-mark.js crashed with rc=$rc (out: $MARK_OUT)"
        return
    fi
    pass "A5: missing session_id → no marker, no crash"
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
    # No session_id, no CLAUDE_ENV_FILE → cannot determine which marker to delete.
    # Must not crash, must not delete anything outside scope.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    write_marker_file "$wfdir" "someone-else"
    local payload
    payload='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: A10 no session id>>\""}, "tool_response":{"exit_code":0}}'
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "A10: hook crashed with no session_id rc=$rc (out: $MARK_OUT)"
        return
    fi
    # Other-session marker MUST still exist (no cross-session deletion).
    if [ ! -f "$wfdir/someone-else.workflow-off" ]; then
        fail "A10: ON sentinel without session_id deleted unrelated marker (out: $MARK_OUT)"
        return
    fi
    pass "A10: no session_id → ON sentinel is a no-op, no cross-session deletion"
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

test_SEC1_path_traversal_rejected() {
    require_mark_js "SEC1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local before_count after_count
    before_count="$(count_workflow_off_files "$wfdir")"
    local payload; payload="$(build_mark_payload "../evil" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: SEC1 traversal>>"' 0)"
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    after_count="$(count_workflow_off_files "$wfdir")"
    if [ "$rc" -ne 0 ]; then
        fail "SEC1: workflow-mark.js crashed with rc=$rc on traversal input (out: $MARK_OUT)"
        return
    fi
    if [ "$after_count" != "$before_count" ]; then
        fail "SEC1: traversal session ID produced a marker file (count $before_count -> $after_count, out: $MARK_OUT)"
        return
    fi
    pass "SEC1: ../evil session ID rejected — no marker, no crash"
}

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
        run_workflow_mark "$payload" "$wfdir" || rc=$?
        after_count="$(count_workflow_off_files "$wfdir")"
        if [ "$rc" -ne 0 ]; then
            fail "SEC2: crash on session ID '$sid' rc=$rc (out: $MARK_OUT)"
            any_failure=1
            continue
        fi
        if [ "$after_count" != "$before_count" ]; then
            fail "SEC2: marker created for malicious session ID '$sid' (count $before_count -> $after_count)"
            any_failure=1
        fi
    done
    if [ "$any_failure" = "0" ]; then
        pass "SEC2: all shell-metachar session IDs rejected — no markers, no crashes"
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

# ============================================================================
# Run all (wrap in 120s wall-clock timeout if available)
# ============================================================================

run_all() {
    # A: sentinel ingestion (OFF)
    test_A1_marker_created_on_sentinel
    test_A2_marker_with_reason
    test_A3_non_zero_exit_skips
    test_A4_env_file_fallback
    test_A5_no_session_id_no_crash
    test_A6_chained_sentinels_accepted
    test_A7_idempotent_marker_write
    # A8-A11: ENFORCE_WORKFLOW_ON sentinel
    test_A8_on_sentinel_deletes_marker
    test_A9_on_sentinel_no_marker_idempotent
    test_A10_on_sentinel_no_session_id
    test_A11_on_sentinel_session_isolation
    # A12-A13: bare-form rejection
    test_A12_bare_off_malformed
    test_A13_bare_on_malformed
    # B: hooks/lib/session-markers.js direct
    test_B1_isworkflowoff_true_when_marker_exists
    test_B2_isworkflowoff_false_when_no_marker
    test_B3_isworkflowoff_wrong_sid_returns_false
    test_B4_isworkflowoff_empty_sid_returns_false
    test_B5_isworkflowoff_traversal_sid_returns_false
    test_B6_isworkflowoff_failclosed_when_getworkflowdir_throws
    test_B7_notice_text_never_throws
    # C: round trip
    test_C1_round_trip_off_creates_and_off_returns_true
    test_C2_marker_removal_returns_false
    test_C3_off_on_round_trip_via_sentinels
    # SEC
    test_SEC1_path_traversal_rejected
    test_SEC2_shell_metachars_rejected
    test_SEC3_env_file_traversal_failclosed
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_WORKFLOW_OFF_TEST_INNER:-}" ]; then
        _WORKFLOW_OFF_TEST_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
