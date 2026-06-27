#!/bin/bash
# tests/feature-1077-issue-close-verified.sh
# Tests: hooks/enforce-issue-close.js, hooks/lib/session-markers.js, hooks/lib/sentinel-patterns.js
# Tags: issue-close, enforce, hook, sentinel, scope:issue-specific
#
# PR: WORKFLOW_ISSUE_CLOSE_VERIFIED sentinel — session-scoped bypass for gh issue close.
#
# Contract (existing hook behavior):
#   - bare `gh issue close N` from Bash → blocked (exit 2 with reason to stderr).
#   - ISSUE_CLOSE_SKILL=1 inherited env → bypass (exit 0).
#   - WORKFLOW_OFF marker present + valid sid → bypass (exit 0).
# New contract (this PR):
#   - .issue-close-verified marker present + valid sid → bypass (exit 0).
#   - traversal sid → bypass NOT granted (SID_RE blocks path traversal).
#   - isSentinel() recognises ISSUE_CLOSE_VERIFIED ON and END forms.
#   - isSentinel() LOOKSLIKE detects bare form (no reason).
#
# L3 gap (what this test does NOT catch):
# - Real Claude session: workflow-mark.js dispatches VERIFIED ON/END echo to
#   enforce-override-handlers.js → writes/removes .issue-close-verified marker
# - End-to-end: user echoes sentinel → next gh issue close is bypassed
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/enforce-issue-close.js"
SENTINEL_PATTERNS_JS="${_AGENTS_DIR_NODE}/hooks/lib/sentinel-patterns.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
xfail() { echo "XFAIL (expected, not yet implemented): $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eissue1077-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_hook() {
    if [ ! -f "$HOOK_JS" ]; then
        fail "$1 (hooks/enforce-issue-close.js not present)"
        return 1
    fi
    return 0
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

write_workflow_off_marker() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.workflow-off"
}

write_issue_close_verified_marker() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.issue-close-verified"
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# A Bash tool payload that, without bypass, would be blocked by enforce-issue-close.
build_close_payload() {
    local sid="$1" n="$2"
    local q_sid q_cmd
    q_sid="$(json_quote "$sid")"
    # Avoid embedding the literal token sequence that may trip outer wrappers.
    q_cmd="$(json_quote "gh issue close $n")"
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$q_sid" "$q_cmd"
}

HOOK_OUT=""
HOOK_ERR=""
HOOK_RC=0
run_hook() {
    local payload="$1" wfdir="$2"
    HOOK_RC=0
    local errfile="$TMPDIR_BASE/.err.$$"
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u ISSUE_CLOSE_SKILL \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$HOOK_JS" 2>"$errfile")" || HOOK_RC=$?
    HOOK_ERR="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
}

run_hook_with_skill() {
    local payload="$1" wfdir="$2"
    HOOK_RC=0
    local errfile="$TMPDIR_BASE/.err.$$"
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "ISSUE_CLOSE_SKILL=1" \
        node "$HOOK_JS" 2>"$errfile")" || HOOK_RC=$?
    HOOK_ERR="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
}

# ============================================================================
# Tests
# ============================================================================

# A: No marker → bare close attempt blocked (exit 2 + stderr mentions /issue-close-finalize).
test_A_no_marker_blocks() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local payload; payload="$(build_close_payload "$sid" 42)"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 2 ]; then
        fail "A: expected exit 2 but got rc=$HOOK_RC (stderr=$HOOK_ERR)"
        return
    fi
    if echo "$HOOK_ERR" | grep -q "issue-close-finalize"; then
        pass "A: no marker → close blocked (exit 2, points at /issue-close-finalize)"
    else
        fail "A: stderr missing /issue-close-finalize hint (stderr=$HOOK_ERR)"
    fi
}

# B: .issue-close-verified marker present + valid sid → bypass (exit 0).
test_B_issue_close_verified_marker_bypasses() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_issue_close_verified_marker "$wfdir" "$sid"
    local payload; payload="$(build_close_payload "$sid" 42)"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -eq 0 ]; then
        pass "B: .issue-close-verified marker present → close bypass granted (exit 0)"
    else
        fail "B: .issue-close-verified marker present → expected exit 0 but got rc=$HOOK_RC"
    fi
}

# C: Traversal sid → bypass NOT granted, hook still blocks (SID_RE validation).
test_C_traversal_sid_no_bypass() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.issue-close-verified"
    local payload; payload="$(build_close_payload "../evil" 42)"
    run_hook "$payload" "$wfdir"
    rm -f "$parent/evil.issue-close-verified" 2>/dev/null || true
    if [ "$HOOK_RC" -eq 2 ]; then
        pass "C: traversal sid → bypass NOT granted, hook still blocks (exit 2)"
    else
        fail "C: traversal sid wrongly bypassed (rc=$HOOK_RC stderr=$HOOK_ERR)"
    fi
}

# D: WORKFLOW_OFF marker still grants bypass (regression — existing bypass must still work).
test_D_workflow_off_still_bypasses() {
    require_hook "D" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_workflow_off_marker "$wfdir" "$sid"
    local payload; payload="$(build_close_payload "$sid" 42)"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -eq 0 ]; then
        pass "D: WORKFLOW_OFF marker → close bypass still granted (exit 0) — no regression"
    else
        fail "D: WORKFLOW_OFF bypass regressed (rc=$HOOK_RC stderr=$HOOK_ERR)"
    fi
}

# E: ISSUE_CLOSE_SKILL=1 env still grants bypass (regression).
test_E_issue_close_skill_env_bypasses() {
    require_hook "E" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local payload; payload="$(build_close_payload "$sid" 42)"
    run_hook_with_skill "$payload" "$wfdir"
    if [ "$HOOK_RC" -eq 0 ]; then
        pass "E: ISSUE_CLOSE_SKILL=1 → close bypass still granted (exit 0) — no regression"
    else
        fail "E: ISSUE_CLOSE_SKILL=1 bypass regressed (rc=$HOOK_RC stderr=$HOOK_ERR)"
    fi
}

# F: isSentinel() recognises ISSUE_CLOSE_VERIFIED ON form (with reason).
test_F_sentinel_issue_close_verified_on_recognized() {
    local result
    result="$(node -e "
const p=require('${_AGENTS_DIR_NODE}/hooks/lib/sentinel-patterns');
const r=p.isSentinel('echo \"<<WORKFLOW_ISSUE_CLOSE_VERIFIED: reason>>\"');
console.log(r);
" 2>/dev/null)"
    if [ "$result" = "true" ]; then
        pass "F: isSentinel() recognises ISSUE_CLOSE_VERIFIED ON form"
    else
        fail "F: isSentinel() does not recognise ISSUE_CLOSE_VERIFIED ON form (got: $result)"
    fi
}

# G: isSentinel() recognises ISSUE_CLOSE_VERIFIED_END OFF form (with reason).
# EXPECTED-FAIL until implementation adds the pattern to sentinel-patterns.js.
test_G_sentinel_issue_close_verified_end_recognized() {
    local result
    result="$(node -e "
const p=require('${_AGENTS_DIR_NODE}/hooks/lib/sentinel-patterns');
const r=p.isSentinel('echo \"<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END: reason>>\"');
console.log(r);
" 2>/dev/null)"
    if [ "$result" = "true" ]; then
        pass "G: isSentinel() recognises ISSUE_CLOSE_VERIFIED_END OFF form"
    else
        xfail "G: isSentinel() does not yet recognise ISSUE_CLOSE_VERIFIED_END OFF form (got: $result — not yet implemented)"
    fi
}

# H: isSentinel() LOOKSLIKE detects bare form (no reason) — returns true via LOOKSLIKE path.
# EXPECTED-FAIL until implementation adds the LOOKSLIKE pattern to sentinel-patterns.js.
test_H_sentinel_issue_close_verified_bare_lookslike() {
    local result
    result="$(node -e "
const p=require('${_AGENTS_DIR_NODE}/hooks/lib/sentinel-patterns');
const r=p.isSentinel('echo \"<<WORKFLOW_ISSUE_CLOSE_VERIFIED>>\"');
console.log(r);
" 2>/dev/null)"
    if [ "$result" = "true" ]; then
        pass "H: isSentinel() LOOKSLIKE detects bare WORKFLOW_ISSUE_CLOSE_VERIFIED (no reason)"
    else
        xfail "H: isSentinel() does not yet detect bare WORKFLOW_ISSUE_CLOSE_VERIFIED via LOOKSLIKE (got: $result — not yet implemented)"
    fi
}

run_all() {
    test_A_no_marker_blocks
    test_B_issue_close_verified_marker_bypasses
    test_C_traversal_sid_no_bypass
    test_D_workflow_off_still_bypasses
    test_E_issue_close_skill_env_bypasses
    test_F_sentinel_issue_close_verified_on_recognized
    test_G_sentinel_issue_close_verified_end_recognized
    test_H_sentinel_issue_close_verified_bare_lookslike
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_1077_INNER:-}" ]; then
        _1077_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
