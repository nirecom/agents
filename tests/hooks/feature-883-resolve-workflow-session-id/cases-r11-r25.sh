# tests/hooks/feature-883-resolve-workflow-session-id/cases-r11-r25.sh
# Test case function definitions for R11-R25 (ensureAlertScheduled integration, charset guard, CLAUDE_CODE_SESSION_ID, ccBucket gate, chain-named artifacts).
# Invocations live in the dispatcher.

# ---------------------------------------------------------------------------
# R11: ensureAlertScheduled integration — confirms depth-score fix prevents
# erroneous L2 arming when the active session has a final-report-env.json.
# Without the depth-score fix, the resolver returns the bare-stub sid (which
# has no final-report-env.json) and L2 gets armed incorrectly.
# ---------------------------------------------------------------------------

run_r11() {
    require_function "resolveWorkflowSessionId" "R11: ensureAlertScheduled honors depth-scored resolver" || return
    local tmp armed_at_out
    tmp="$(mktemp -d)"
    # depth=2 active session, older mtime
    : > "$tmp/${TODAY}-active-r11-context.md"
    : > "$tmp/${TODAY}-active-r11-intent.md"
    : > "$tmp/${TODAY}-active-r11-detail.md"
    # depth=0 stub session, newer mtime
    : > "$tmp/${TODAY}-stub-r11-context.md"
    # active session has a final-report-env.json -> L2 must NOT be armed
    mkdir -p "$tmp/${TODAY}-active-r11.control"  # #2434 control file
    echo '{}' > "$tmp/${TODAY}-active-r11.control/final-report-env.json"
    set_mtimes \
        "$tmp/${TODAY}-active-r11-context.md" -10 \
        "$tmp/${TODAY}-active-r11-intent.md" -10 \
        "$tmp/${TODAY}-active-r11-detail.md" -10 \
        "$tmp/${TODAY}-stub-r11-context.md" -2

    # Run ensureAlertScheduled with CWD = tmp (no WORKTREE_NOTES.md there ->
    # resolver falls through Priority 1 -> Priority 3 depth-scan). The stub cc
    # sid validates against SESSION_ID_RE but has no final-report-env.json;
    # only the resolver-found active sid carries the final-report-env marker.
    armed_at_out=$(cd "$tmp" && WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp" run_with_timeout 5 env -u CLAUDE_CODE_SESSION_ID node -e "
const m = require('$SUPERVISOR_STATE_WRITER_NODE');
const state = { layer2: { alert_armed_at: null, alert_phase: null } };
m.ensureAlertScheduled(state, '${TODAY}-stub-r11cc');
process.stdout.write(state.layer2.alert_armed_at == null ? 'NOT_ARMED' : 'ARMED');
" 2>/dev/null)
    rm -rf "$tmp"
    if [ "$armed_at_out" = "NOT_ARMED" ]; then
        pass "R11: ensureAlertScheduled honors depth-scored resolver (no arm when active has final-report)"
    else
        fail "R11: ensureAlertScheduled honors depth-scored resolver (expected NOT_ARMED, got $armed_at_out)"
    fi
}

run_r12() {
    require_function "resolveWorkflowSessionId" "R12: invalid charset in Session-ID value (P1 path-traversal guard)" || return
    local tmp out
    tmp="$(mktemp -d)"
    # P1 path-traversal guard: Session-ID value contains dots and slashes
    # -> /^[A-Za-z0-9_-]+$/ fails -> P1 returns null -> falls through to P3.
    printf "Session-ID: ../../../someval\n" > "$tmp/WORKTREE_NOTES.md"
    # Create active context+intent files (depth=1) so P3 picks them up.
    : > "$tmp/${TODAY}r12active-context.md"
    : > "$tmp/${TODAY}r12active-intent.md"
    # Use call_resolve with work_dir=$tmp so P1 reads WORKTREE_NOTES.md from $tmp,
    # finds the invalid Session-ID, returns null, and P3 scans $tmp for context.md.
    out=$(call_resolve "$tmp" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}r12active" ]; then
        pass "R12: invalid charset in Session-ID value (P1 path-traversal guard) -> P3 fallback"
    else
        fail "R12: invalid charset in Session-ID value (P1 path-traversal guard) (out=$out)"
    fi
}

run_r13() {
    require_function "resolveWorkflowSessionId" "R13: 2 stubs identical mtime, no env (both ccBucket=1) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Two context.md stubs with depth=0, identical mtime. Both ccBucket=1 (no env). Gate fires → NULL.
    : > "$tmp/${TODAY}r13b-context.md"
    : > "$tmp/${TODAY}r13a-context.md"
    # Set both to the same timestamp (now - 5 seconds).
    node -e "
const fs=require('fs');
const t=(Date.now()-5000)/1000;
fs.utimesSync(process.argv[1],t,t);
fs.utimesSync(process.argv[2],t,t);
" -- "$tmp/${TODAY}r13b-context.md" "$tmp/${TODAY}r13a-context.md" 2>/dev/null
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R13: 2 stubs identical mtime, no env (both ccBucket=1) -> NULL"
    else
        fail "R13: 2 stubs identical mtime, no env (both ccBucket=1) -> NULL (out=$out)"
    fi
}

run_r15() {
    require_function "resolveWorkflowSessionId" "R15: 2 depth=2 sessions, no env (both ccBucket=1) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Both sessions have depth=2 (detail.md present); mtime differs on context.md.
    # Both ccBucket=1 (no env): gate fires → NULL.
    : > "$tmp/${TODAY}r15early-context.md"
    : > "$tmp/${TODAY}r15early-detail.md"
    : > "$tmp/${TODAY}r15later-context.md"
    : > "$tmp/${TODAY}r15later-detail.md"
    node -e "
const fs=require('fs');
const early=(Date.now()-10000)/1000;
const later=(Date.now()-2000)/1000;
const base=process.argv[1];
fs.utimesSync(base+'/${TODAY}r15early-context.md',early,early);
fs.utimesSync(base+'/${TODAY}r15later-context.md',later,later);
" -- "$tmp" 2>/dev/null
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R15: 2 depth=2 sessions, no env (both ccBucket=1) -> NULL"
    else
        fail "R15: 2 depth=2 sessions, no env (both ccBucket=1) -> NULL (out=$out)"
    fi
}

run_r16() {
    require_function "resolveWorkflowSessionId" "R16: whitespace-only Session-ID falls through to P3" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Session-ID: <space> — \S+ in regex requires non-whitespace; fails match -> P1 null.
    printf "Session-ID: \n" > "$tmp/WORKTREE_NOTES.md"
    : > "$tmp/${TODAY}r16active-context.md"
    : > "$tmp/${TODAY}r16active-intent.md"
    out=$(call_resolve "$tmp" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}r16active" ]; then
        pass "R16: whitespace-only Session-ID (P1 falls through to P3)"
    else
        fail "R16: whitespace-only Session-ID fallthrough (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# R17: CLAUDE_CODE_SESSION_ID beats newer foreign context.md (concurrent-session fix).
# A foreign session's context.md has newer mtime; own-sid artifacts exist in plans-dir.
# CLAUDE_CODE_SESSION_ID existence-guarded: accepted because own-sid-*.md artifact exists.
# ---------------------------------------------------------------------------

run_r17() {
    require_function "resolveWorkflowSessionId" "R17: CLAUDE_CODE_SESSION_ID beats newer foreign context.md" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Own session has artifact (context+intent, depth=1), older mtime T-10.
    : > "$tmp/${TODAY}-r17own-context.md"
    : > "$tmp/${TODAY}-r17own-intent.md"
    # Foreign session is a depth=2 session with newer mtime T-2 — would win depth+mtime sort.
    : > "$tmp/${TODAY}-r17foreign-context.md"
    : > "$tmp/${TODAY}-r17foreign-intent.md"
    : > "$tmp/${TODAY}-r17foreign-detail.md"
    set_mtimes \
        "$tmp/${TODAY}-r17own-context.md" -10 \
        "$tmp/${TODAY}-r17own-intent.md" -10 \
        "$tmp/${TODAY}-r17foreign-context.md" -2 \
        "$tmp/${TODAY}-r17foreign-intent.md" -2 \
        "$tmp/${TODAY}-r17foreign-detail.md" -2
    out=$(call_resolve_with_code_sid "$tmp" "${TODAY}-r17own" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-r17own" ]; then
        pass "R17: CLAUDE_CODE_SESSION_ID beats newer foreign context.md (concurrent-session fix)"
    else
        fail "R17: CLAUDE_CODE_SESSION_ID beats newer foreign context.md (out=$out, expected ${TODAY}-r17own)"
    fi
}

# ---------------------------------------------------------------------------
# R18: CLAUDE_CODE_SESSION_ID existence-guard — no artifact → falls through to P3.
# When CLAUDE_CODE_SESSION_ID is set but no <value>-*.md artifact exists in plans-dir,
# the resolver must NOT return it; it must fall through to the depth-scan (P3).
# ---------------------------------------------------------------------------

run_r18() {
    require_function "resolveWorkflowSessionId" "R18: CLAUDE_CODE_SESSION_ID without artifact falls through to P3" || return
    local tmp out
    tmp="$(mktemp -d)"
    # own-sid has NO artifact in plans-dir.
    # A foreign session has a valid context+intent — should be returned via P3.
    : > "$tmp/${TODAY}-r18foreign-context.md"
    : > "$tmp/${TODAY}-r18foreign-intent.md"
    set_mtimes \
        "$tmp/${TODAY}-r18foreign-context.md" -4 \
        "$tmp/${TODAY}-r18foreign-intent.md" -4
    out=$(call_resolve_with_code_sid "$tmp" "${TODAY}-r18own-no-artifact" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-r18foreign" ]; then
        pass "R18: CLAUDE_CODE_SESSION_ID without artifact falls through to P3 depth-scan"
    else
        fail "R18: CLAUDE_CODE_SESSION_ID without artifact (out=$out, expected ${TODAY}-r18foreign)"
    fi
}

# ---------------------------------------------------------------------------
# R19: CLAUDE_CODE_SESSION_ID unset → P3 depth-scan still works (no regression).
# Verifies the fix did not break headless/CI paths where CLAUDE_CODE_SESSION_ID
# is absent.
# ---------------------------------------------------------------------------

run_r19() {
    require_function "resolveWorkflowSessionId" "R19: CLAUDE_CODE_SESSION_ID unset, active+stub, no env (both ccBucket=1) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-r19active-context.md"
    : > "$tmp/${TODAY}-r19active-intent.md"
    : > "$tmp/${TODAY}-r19stub-context.md"
    # CLAUDE_CODE_SESSION_ID unset, no env. Both ccBucket=1: gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-r19active-context.md" -8 \
        "$tmp/${TODAY}-r19active-intent.md" -8 \
        "$tmp/${TODAY}-r19stub-context.md" -2
    out=$(call_resolve "$tmp" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R19: CLAUDE_CODE_SESSION_ID unset, active+stub, no env (both ccBucket=1) -> NULL"
    else
        fail "R19: CLAUDE_CODE_SESSION_ID unset, both ccBucket=1 -> NULL (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# R20: primary gate demonstration — multiple candidates, no ccBucket=0 → NULL.
# Two empty context.md stubs, no env: ccBucket=1 for both → gate fires → NULL.
# ---------------------------------------------------------------------------

run_r20() {
    require_function "resolveWorkflowSessionId" "R20: multiple candidates, no ccBucket=0 -> gate fires -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Two empty stubs; no env → ccUuid="" → ccBucket=1 for all candidates. Gate fires → NULL.
    : > "$tmp/${TODAY}-r20alpha-context.md"
    : > "$tmp/${TODAY}-r20beta-context.md"
    set_mtimes \
        "$tmp/${TODAY}-r20alpha-context.md" -6 \
        "$tmp/${TODAY}-r20beta-context.md" -2
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R20: multiple candidates, no ccBucket=0 -> gate fires -> NULL"
    else
        fail "R20: multiple candidates, no ccBucket=0 -> gate fires -> NULL (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# R21: single candidate, no env → gate skipped → returns sid.
# Gate condition is: !candidates.some(c=>c.ccBucket===0) && candidates.length > 1.
# With exactly 1 candidate, candidates.length > 1 is false → gate does NOT fire.
# ---------------------------------------------------------------------------

run_r21() {
    require_function "resolveWorkflowSessionId" "R21: single candidate, no env -> gate skipped -> returns sid" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Exactly one candidate; no env → ccBucket=1, but candidates.length=1 → gate skipped.
    : > "$tmp/${TODAY}-r21solo-context.md"
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-r21solo" ]; then
        pass "R21: single candidate, no env -> gate skipped -> returns sid"
    else
        fail "R21: single candidate, no env -> gate skipped -> returns sid (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# R22: multiple candidates, one ccBucket=0 -> gate NOT fired -> ccBucket=0 wins.
# Gate: !candidates.some(c=>c.ccBucket===0) && candidates.length > 1.
# When owner context.md has CC UUID, ccBucket=0 -> !some() is FALSE -> dormant.
# Validates gate does NOT over-fire when ccBucket=0 is present.
# #1091: the CC UUID comes from CLAUDE_CODE_SESSION_ID (no <UUID>-*.md, so P2 skips).
# ---------------------------------------------------------------------------

run_r22() {
    require_function "resolveWorkflowSessionId" "R22: multiple candidates, one ccBucket=0 -> gate dormant -> ccBucket=0 wins" || return
    local tmp out ccuuid
    tmp="$(mktemp -d)"
    ccuuid="2a7d4c10-2222-4333-8444-955566667777"
    # Owner: context.md has CC UUID -> ccBucket=0.
    printf "Session-ID: %s\n%s\n" "${TODAY}-r22owner" "$ccuuid" > "$tmp/${TODAY}-r22owner-context.md"
    # Foreign: empty context.md -> ccBucket=1; newer mtime still loses ccBucket sort.
    : > "$tmp/${TODAY}-r22foreign-context.md"
    set_mtimes \
        "$tmp/${TODAY}-r22owner-context.md" -10 \
        "$tmp/${TODAY}-r22foreign-context.md" -2
    out=$(call_resolve_with_code_sid "$tmp" "$ccuuid" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-r22owner" ]; then
        pass "R22: multiple candidates, one ccBucket=0 -> gate dormant -> ccBucket=0 wins"
    else
        fail "R22: multiple candidates, one ccBucket=0 -> gate dormant -> ccBucket=0 wins (out=$out, expected ${TODAY}-r22owner)"
    fi
}

# ---------------------------------------------------------------------------
# R23 (#1091): CLAUDE_CODE_SESSION_ID feeds the P4 ccBucket even when P2 skips for
# lack of a <UUID>-*.md artifact. The UUID-bearing stub beats a deeper, newer foreign
# session, so hook/Bash paths without the old env-file relay still resolve their own sid.
# ---------------------------------------------------------------------------

run_r23() {
    require_function "resolveWorkflowSessionId" "R23: native UUID ccBucket beats deeper newer foreign session" || return
    local tmp out ccuuid
    tmp="$(mktemp -d)"
    ccuuid="5f3c2a10-1111-4222-8333-944455556666"
    printf "Session-ID: %s\ncc: %s\n" "${TODAY}-r23own" "$ccuuid" > "$tmp/${TODAY}-r23own-context.md"
    : > "$tmp/${TODAY}-r23foreign-context.md"
    : > "$tmp/${TODAY}-r23foreign-intent.md"
    : > "$tmp/${TODAY}-r23foreign-detail.md"
    set_mtimes \
        "$tmp/${TODAY}-r23own-context.md" -10 \
        "$tmp/${TODAY}-r23foreign-context.md" -2
    out=$(call_resolve_with_code_sid "$tmp" "$ccuuid" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-r23own" ]; then
        pass "R23: native UUID ccBucket beats deeper newer foreign session"
    else
        fail "R23: native UUID ccBucket beats deeper newer foreign session (out=$out, expected ${TODAY}-r23own)"
    fi
}

# ---------------------------------------------------------------------------
# R24 (#1091): a malformed CLAUDE_CODE_SESSION_ID must disable the ccBucket, even when
# a context.md happens to contain that raw string -> multiple candidates -> NULL.
# ---------------------------------------------------------------------------

run_r24() {
    require_function "resolveWorkflowSessionId" "R24: malformed native sid disables ccBucket -> NULL" || return
    local tmp out bad
    tmp="$(mktemp -d)"
    bad="../x"
    printf "Session-ID: %s\n%s\n" "${TODAY}-r24a" "$bad" > "$tmp/${TODAY}-r24a-context.md"
    : > "$tmp/${TODAY}-r24b-context.md"
    set_mtimes \
        "$tmp/${TODAY}-r24a-context.md" -10 \
        "$tmp/${TODAY}-r24b-context.md" -2
    out=$(call_resolve_with_code_sid "$tmp" "$bad" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R24: malformed native sid disables ccBucket -> NULL"
    else
        fail "R24: malformed native sid disables ccBucket -> NULL (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# R25 (#2748): a session-downstream B (previous_session_ids [A]) has no <B>-*.md, but its
# chain's plans carry the first_session_id name A. Priority 2 accepts the native sid B through
# the A-named artifact and still returns B (not the P4 single candidate A).
# ---------------------------------------------------------------------------

run_r25() {
    require_function "resolveWorkflowSessionId" "R25: native sid with only first_session_id-named artifacts resolves to itself" || return
    local tmp state_dir out first down
    tmp="$(mktemp -d)"
    state_dir="$tmp/state"
    mkdir -p "$state_dir"
    first="${TODAY}-r25first"
    down="${TODAY}-r25down"
    : > "$tmp/${first}-context.md"
    : > "$tmp/${first}-intent.md"
    WORKFLOW_STATE_DIR="$state_dir" WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const S = require('$STATE_IO_NODE');
const ctx = { cwd: '/fixture/up', git_branch: 'feature/up', transcript_path: '/fixture/t/up.jsonl' };
S.writeState('$first', S.createInitialState('$first', ctx));
const st = S.createInitialState('$down', ctx);
st.previous_session_ids = ['$first'];
st.upstream_session_id = '$first';
S.writeState('$down', st);
" 2>/dev/null
    out=$(cd "$tmp" && WORKFLOW_STATE_DIR="$state_dir" WORKFLOW_PLANS_DIR="$tmp" CLAUDE_CODE_SESSION_ID="$down" \
        run_with_timeout 5 node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null)
    rm -rf "$tmp"
    if [ "$out" = "$down" ]; then
        pass "R25: native sid with only first_session_id-named artifacts resolves to itself"
    else
        fail "R25: native sid with only first_session_id-named artifacts (out=$out, expected $down)"
    fi
}
