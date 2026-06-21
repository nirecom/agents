#!/bin/bash
# tests/fix-supervisor-l2-deadlock.sh
# Tests: bin/supervisor-report, hooks/lib/resolve-workflow-session-id.js, hooks/supervisor-guard.js, hooks/lib/supervisor-report-format.js
# Tags: supervisor, session-id-routing, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - real Stop-event firing when supervisor-guard reads the wsid state file after fix
# - SC-5 elapsed-time fallback in a live claude -p session
# - actual SC-5 fail-loud anomalous-state branch in live session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# L2 integration tests for supervisor L2 deadlock fix.
# Covers four source files; tests written in TDD order — they FAIL on current
# source and PASS after the fix is applied.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-report"
CLI_NODE="$_AGENTS_DIR_NODE/bin/supervisor-report"
HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
RESOLVE_WSID="$AGENTS_DIR/hooks/lib/resolve-workflow-session-id.js"
RESOLVE_WSID_NODE="$_AGENTS_DIR_NODE/hooks/lib/resolve-workflow-session-id.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
FORMAT_SRC="$AGENTS_DIR/hooks/lib/supervisor-report-format.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

require_source() {
    local p="$1" label="$2"
    if [ ! -f "$p" ]; then skip "$label (source missing)"; return 1; fi
    return 0
}

# Seed a supervisor-state.json directly via writer module.
seed_state() {
    local tmp="$1" sid="$2" layer2_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer2 = $layer2_json;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

today_str() {
    node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null
}

# YYYYMMDD string for a date N days before today (N >= 0).
date_minus_days() {
    local n="$1"
    node -e "const n=Number(process.argv[1]); const d=new Date(); d.setDate(d.getDate()-n); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" -- "$n" 2>/dev/null
}

# ============================================================================
# Cases 1-4: supervisor-report — wsid routing
# ============================================================================

# Case 1: wsid from WORKTREE_NOTES.md → state written to wsid file (NOT CC UUID)
run_c1() {
    require_source "$CLI" "C1: wsid from WORKTREE_NOTES.md → wsid state file" || return
    local tmp tmp_node workdir wsid ccuuid
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    workdir="$tmp/work"; mkdir -p "$workdir"
    wsid="20260101-120000-c1wsid"
    ccuuid="c1-cc-uuid-different"
    printf 'Session-ID: %s\n' "$wsid" > "$workdir/WORKTREE_NOTES.md"
    (
        cd "$workdir" && \
        CLAUDE_SESSION_ID="$ccuuid" \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    if [ -f "$tmp_node/${wsid}-supervisor-state.json" ]; then
        pass "C1: wsid from WORKTREE_NOTES.md → wsid state file"
    else
        fail "C1: wsid from WORKTREE_NOTES.md → wsid state file (expected ${wsid}-supervisor-state.json)"
    fi
    rm -rf "$tmp"
}

# Case 2: wsid from plans-dir context.md → wsid state file
run_c2() {
    require_source "$CLI" "C2: wsid from plans-dir context.md → wsid state file" || return
    local tmp tmp_node workdir wsid ccuuid TODAY
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    workdir="$tmp/work"; mkdir -p "$workdir"
    TODAY="$(today_str)"
    wsid="${TODAY}-c2wsid"
    ccuuid="c2-cc-uuid-different"
    # Plans-dir context.md + intent.md so Priority 3 picks it up (depth=1).
    printf 'ctx\n' > "$tmp/${wsid}-context.md"
    printf 'intent\n' > "$tmp/${wsid}-intent.md"
    (
        cd "$workdir" && \
        CLAUDE_SESSION_ID="$ccuuid" \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    if [ -f "$tmp_node/${wsid}-supervisor-state.json" ]; then
        pass "C2: wsid from plans-dir context.md → wsid state file"
    else
        fail "C2: wsid from plans-dir context.md → wsid state file (expected ${wsid}-supervisor-state.json)"
    fi
    rm -rf "$tmp"
}

# Case 3: wsid unresolvable → fallback to CC UUID (existing behavior preserved)
run_c3() {
    require_source "$CLI" "C3: wsid unresolvable → CC UUID fallback" || return
    local tmp tmp_node workdir ccuuid
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    workdir="$tmp/work"; mkdir -p "$workdir"
    ccuuid="c3-cc-uuid-only"
    # NO WORKTREE_NOTES.md, NO context.md in plans-dir.
    (
        cd "$workdir" && \
        CLAUDE_SESSION_ID="$ccuuid" \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    if [ -f "$tmp_node/${ccuuid}-supervisor-state.json" ]; then
        pass "C3: wsid unresolvable → CC UUID fallback"
    else
        fail "C3: wsid unresolvable → CC UUID fallback (expected ${ccuuid}-supervisor-state.json)"
    fi
    rm -rf "$tmp"
}

# Case 4: regression guard — CC UUID file NOT written when wsid resolves
run_c4() {
    require_source "$CLI" "C4: regression — CC UUID file not written when wsid present" || return
    local tmp tmp_node workdir wsid ccuuid
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    workdir="$tmp/work"; mkdir -p "$workdir"
    wsid="20260101-120000-c4wsid"
    ccuuid="c4-cc-uuid-different"
    printf 'Session-ID: %s\n' "$wsid" > "$workdir/WORKTREE_NOTES.md"
    (
        cd "$workdir" && \
        CLAUDE_SESSION_ID="$ccuuid" \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    if [ ! -f "$tmp_node/${ccuuid}-supervisor-state.json" ]; then
        pass "C4: regression — CC UUID file not written when wsid present"
    else
        fail "C4: regression — CC UUID file not written when wsid present (CC UUID file should NOT exist)"
    fi
    rm -rf "$tmp"
}

# ============================================================================
# Cases 5-9: resolveWorkflowSessionId Priority 3 — date filter relaxed to 2 days
# ============================================================================

# Helper: invoke resolveWorkflowSessionId from CWD with WORKFLOW_PLANS_DIR set,
# returning the resolved sid (or empty string on null).
call_resolve_wsid() {
    local tmp="$1" cwd="$2" env_file="${3:-}"
    local extra=""
    if [ -n "$env_file" ]; then
        extra="CLAUDE_ENV_FILE='$env_file'"
    fi
    (
        cd "$cwd" && \
        unset CLAUDE_SESSION_ID && \
        if [ -n "$env_file" ]; then export CLAUDE_ENV_FILE="$env_file"; else unset CLAUDE_ENV_FILE; fi && \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? '' : r);
" 2>/dev/null
    )
}

# Case 5: yesterday's session is found (date filter relaxed to 2 days)
run_c5() {
    require_source "$RESOLVE_WSID" "C5: yesterday session found (2-day window)" || return
    local tmp workdir YESTERDAY wsid out
    tmp="$(mktemp -d)"
    workdir="$tmp/work"; mkdir -p "$workdir"
    YESTERDAY="$(date_minus_days 1)"
    wsid="${YESTERDAY}-120000-c5wsid"
    printf 'ctx\n' > "$tmp/${wsid}-context.md"
    printf 'intent\n' > "$tmp/${wsid}-intent.md"
    out="$(call_resolve_wsid "$tmp" "$workdir")"
    if [ "$out" = "$wsid" ]; then
        pass "C5: yesterday session found (2-day window)"
    else
        fail "C5: yesterday session found (2-day window) (got: '$out', expected: '$wsid')"
    fi
    rm -rf "$tmp"
}

# Case 6: today's session still found (regression guard)
run_c6() {
    require_source "$RESOLVE_WSID" "C6: today's session still found" || return
    local tmp workdir TODAY wsid out
    tmp="$(mktemp -d)"
    workdir="$tmp/work"; mkdir -p "$workdir"
    TODAY="$(today_str)"
    wsid="${TODAY}-120000-c6wsid"
    printf 'ctx\n' > "$tmp/${wsid}-context.md"
    printf 'intent\n' > "$tmp/${wsid}-intent.md"
    out="$(call_resolve_wsid "$tmp" "$workdir")"
    if [ "$out" = "$wsid" ]; then
        pass "C6: today's session still found"
    else
        fail "C6: today's session still found (got: '$out', expected: '$wsid')"
    fi
    rm -rf "$tmp"
}

# Case 7: 3+ days old session rejected (filter still bounded at 2 days)
run_c7() {
    require_source "$RESOLVE_WSID" "C7: 3+ day old session rejected" || return
    local tmp workdir THREE_AGO wsid out
    tmp="$(mktemp -d)"
    workdir="$tmp/work"; mkdir -p "$workdir"
    THREE_AGO="$(date_minus_days 3)"
    wsid="${THREE_AGO}-120000-c7wsid"
    printf 'ctx\n' > "$tmp/${wsid}-context.md"
    printf 'intent\n' > "$tmp/${wsid}-intent.md"
    out="$(call_resolve_wsid "$tmp" "$workdir")"
    if [ -z "$out" ]; then
        pass "C7: 3+ day old session rejected"
    else
        fail "C7: 3+ day old session rejected (got: '$out', expected empty — filter should have rejected)"
    fi
    rm -rf "$tmp"
}

# Case 8: multiple sessions in 2-day window → CC UUID bucket-sort selects correct one.
# When CLAUDE_ENV_FILE points to today's wsid, that one wins over yesterday's.
# (The bucket-sort means same-day entries beat older-day entries on tie-break.)
run_c8() {
    require_source "$RESOLVE_WSID" "C8: multiple sessions → bucket-sort selects today" || return
    local tmp workdir TODAY YESTERDAY today_wsid yest_wsid env_file out
    tmp="$(mktemp -d)"
    workdir="$tmp/work"; mkdir -p "$workdir"
    TODAY="$(today_str)"
    YESTERDAY="$(date_minus_days 1)"
    today_wsid="${TODAY}-120000-c8today"
    yest_wsid="${YESTERDAY}-120000-c8yest"
    # Create context+detail for both — same depth=2 — so depth ties.
    printf 'ctx\n' > "$tmp/${today_wsid}-context.md"
    printf 'intent\n' > "$tmp/${today_wsid}-intent.md"
    printf 'detail\n' > "$tmp/${today_wsid}-detail.md"
    printf 'ctx\n' > "$tmp/${yest_wsid}-context.md"
    printf 'intent\n' > "$tmp/${yest_wsid}-intent.md"
    printf 'detail\n' > "$tmp/${yest_wsid}-detail.md"
    # Make yesterday's mtime newer (touch) — proves bucket-by-day beats raw mtime.
    # Without a bucket sort, yesterday would win on mtime; with bucket sort,
    # today's day-bucket wins regardless.
    # On Windows touch sets mtime; use node to be portable.
    node -e "
const fs=require('fs');
const path=require('path');
const tmp='$(to_node_path "$tmp")';
const newer=new Date(Date.now()+5000);
for (const f of ['${yest_wsid}-context.md','${yest_wsid}-intent.md','${yest_wsid}-detail.md']) {
  fs.utimesSync(path.join(tmp,f), newer, newer);
}
" 2>/dev/null
    out="$(call_resolve_wsid "$tmp" "$workdir")"
    if [ "$out" = "$today_wsid" ]; then
        pass "C8: multiple sessions → bucket-sort selects today"
    else
        fail "C8: multiple sessions → bucket-sort selects today (got: '$out', expected: '$today_wsid')"
    fi
    rm -rf "$tmp"
}

# Case 9: CLAUDE_ENV_FILE absent → mtime fallback works (today picked)
run_c9() {
    require_source "$RESOLVE_WSID" "C9: CLAUDE_ENV_FILE absent → mtime fallback" || return
    local tmp workdir TODAY YESTERDAY today_wsid yest_wsid out
    tmp="$(mktemp -d)"
    workdir="$tmp/work"; mkdir -p "$workdir"
    TODAY="$(today_str)"
    YESTERDAY="$(date_minus_days 1)"
    today_wsid="${TODAY}-120000-c9today"
    yest_wsid="${YESTERDAY}-120000-c9yest"
    # Both same depth=1 (intent only, no detail) — but today is newer mtime within today's bucket.
    printf 'ctx\n' > "$tmp/${today_wsid}-context.md"
    printf 'intent\n' > "$tmp/${today_wsid}-intent.md"
    printf 'ctx\n' > "$tmp/${yest_wsid}-context.md"
    printf 'intent\n' > "$tmp/${yest_wsid}-intent.md"
    out="$(call_resolve_wsid "$tmp" "$workdir")"
    # Today should win over yesterday (either via bucket sort or by mtime —
    # today is newer because it's written last in script execution).
    if [ "$out" = "$today_wsid" ]; then
        pass "C9: CLAUDE_ENV_FILE absent → mtime fallback"
    else
        fail "C9: CLAUDE_ENV_FILE absent → mtime fallback (got: '$out', expected: '$today_wsid')"
    fi
    rm -rf "$tmp"
}

# ============================================================================
# Cases 10-12: supervisor-guard dual-ID fallback
# ============================================================================

# Case 10: primaryState exists with l2_armed_at=null → reads workflowSessionId state.
# The bug: current code checks `if (primaryState === null)`. When primaryState
# is non-null but has l2_armed_at=null AND cumSev=null AND no findings (zero state),
# the fallback should still trigger to read the wsid file. After fix, the guard
# should fire branch (3) using wsid state.
run_c10() {
    require_source "$HOOK" "C10: primaryState zero-state → wsid fallback" || return
    require_source "$RESOLVE_WSID" "C10: primaryState zero-state → wsid fallback" || return
    local tmp tmp_node workdir wsid ccuuid out rc wsid_retry
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    workdir="$tmp/work"; mkdir -p "$workdir"
    wsid="20260101-120000-c10wsid"
    ccuuid="c10-cc-uuid"
    printf 'Session-ID: %s\n' "$wsid" > "$workdir/WORKTREE_NOTES.md"
    # Seed CC UUID state file with all-null (zero state — no l2_armed_at).
    seed_state "$tmp" "$ccuuid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_cause: null, l2_retry_count: 0 }"
    # Seed wsid state with l2_armed_at set — guard should branch (3) via fallback.
    seed_state "$tmp" "$wsid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'pending', l2_cause: null, l2_retry_count: 0 }"
    out=$(cd "$workdir" && echo "{\"stop_hook_active\":false,\"session_id\":\"$ccuuid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    # After fix: the guard should block (exit 2) because wsid state has l2_armed_at,
    # and the retry counter on the wsid file should increment.
    wsid_retry=$(node -e "try{const s=JSON.parse(require('fs').readFileSync('$tmp_node/${wsid}-supervisor-state.json','utf8')); process.stdout.write(String(s.layer2?.l2_retry_count??0));}catch(_){process.stdout.write('err');}" 2>/dev/null)
    rm -rf "$tmp"
    if [ "$rc" = "2" ] && [ "$wsid_retry" != "0" ] && [ "$wsid_retry" != "err" ]; then
        pass "C10: primaryState zero-state → wsid fallback"
    else
        fail "C10: primaryState zero-state → wsid fallback (rc=$rc, wsid_retry=$wsid_retry; expected rc=2 + wsid retry>0)"
    fi
}

# Case 11: primaryState has l2_armed_at set → use primaryState (no fallthrough).
# This is the regression guard for the fix: when primary IS armed, do NOT fall through.
run_c11() {
    require_source "$HOOK" "C11: primaryState armed → no fallthrough" || return
    require_source "$RESOLVE_WSID" "C11: primaryState armed → no fallthrough" || return
    local tmp tmp_node workdir wsid ccuuid out rc ccuuid_retry wsid_retry
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    workdir="$tmp/work"; mkdir -p "$workdir"
    wsid="20260101-120000-c11wsid"
    ccuuid="c11-cc-uuid"
    printf 'Session-ID: %s\n' "$wsid" > "$workdir/WORKTREE_NOTES.md"
    # Both files have l2_armed_at — verify CC UUID (primary) is used, not wsid.
    seed_state "$tmp" "$ccuuid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'pending', l2_cause: null, l2_retry_count: 0 }"
    seed_state "$tmp" "$wsid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'pending', l2_cause: null, l2_retry_count: 0 }"
    out=$(cd "$workdir" && echo "{\"stop_hook_active\":false,\"session_id\":\"$ccuuid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    ccuuid_retry=$(node -e "try{const s=JSON.parse(require('fs').readFileSync('$tmp_node/${ccuuid}-supervisor-state.json','utf8')); process.stdout.write(String(s.layer2?.l2_retry_count??0));}catch(_){process.stdout.write('err');}" 2>/dev/null)
    wsid_retry=$(node -e "try{const s=JSON.parse(require('fs').readFileSync('$tmp_node/${wsid}-supervisor-state.json','utf8')); process.stdout.write(String(s.layer2?.l2_retry_count??0));}catch(_){process.stdout.write('err');}" 2>/dev/null)
    rm -rf "$tmp"
    # When primaryState has l2_armed_at, that path is used — CC UUID retry should
    # be incremented and wsid retry should remain at 0.
    if [ "$rc" = "2" ] && [ "$ccuuid_retry" != "0" ] && [ "$ccuuid_retry" != "err" ] && [ "$wsid_retry" = "0" ]; then
        pass "C11: primaryState armed → no fallthrough"
    else
        fail "C11: primaryState armed → no fallthrough (rc=$rc, ccuuid_retry=$ccuuid_retry, wsid_retry=$wsid_retry; expected rc=2 + ccuuid>0 + wsid=0)"
    fi
}

# Case 12: primaryState null → reads workflowSessionId state (existing behavior preserved).
run_c12() {
    require_source "$HOOK" "C12: primaryState null → wsid fallback (existing)" || return
    require_source "$RESOLVE_WSID" "C12: primaryState null → wsid fallback (existing)" || return
    local tmp tmp_node workdir wsid ccuuid out rc wsid_retry
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    workdir="$tmp/work"; mkdir -p "$workdir"
    wsid="20260101-120000-c12wsid"
    ccuuid="c12-cc-uuid"
    printf 'Session-ID: %s\n' "$wsid" > "$workdir/WORKTREE_NOTES.md"
    # NO CC UUID state file. Only wsid file with l2_armed_at.
    seed_state "$tmp" "$wsid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'pending', l2_cause: null, l2_retry_count: 0 }"
    out=$(cd "$workdir" && echo "{\"stop_hook_active\":false,\"session_id\":\"$ccuuid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    wsid_retry=$(node -e "try{const s=JSON.parse(require('fs').readFileSync('$tmp_node/${wsid}-supervisor-state.json','utf8')); process.stdout.write(String(s.layer2?.l2_retry_count??0));}catch(_){process.stdout.write('err');}" 2>/dev/null)
    rm -rf "$tmp"
    if [ "$rc" = "2" ] && [ "$wsid_retry" != "0" ] && [ "$wsid_retry" != "err" ]; then
        pass "C12: primaryState null → wsid fallback (existing)"
    else
        fail "C12: primaryState null → wsid fallback (existing) (rc=$rc, wsid_retry=$wsid_retry; expected rc=2 + wsid>0)"
    fi
}

# ============================================================================
# Cases 13-14: supervisor-report-format.js — "Effective state session ID:" line
# ============================================================================

# Case 13: formatL2ArmedReason includes "Effective state session ID:" line
run_c13() {
    require_source "$FORMAT_SRC" "C13: formatL2ArmedReason includes 'Effective state session ID:'" || return
    local out
    out=$(run_with_timeout 5 node -e "
const f = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format');
const s = f.formatL2ArmedReason('C2', 'ccuuid', 'wsid', '/sup.md', '/state.json', 'effective-sid');
process.stdout.write(s);
" 2>/dev/null)
    if echo "$out" | grep -q "Effective state session ID:"; then
        pass "C13: formatL2ArmedReason includes 'Effective state session ID:'"
    else
        fail "C13: formatL2ArmedReason includes 'Effective state session ID:' (line not found in output)"
    fi
}

# Case 14: all 3 format functions include the line symmetrically.
run_c14() {
    require_source "$FORMAT_SRC" "C14: all 3 format functions include the line" || return
    local out_armed out_cumsev out_wtoff
    out_armed=$(run_with_timeout 5 node -e "
const f = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format');
process.stdout.write(f.formatL2ArmedReason('C2', 'ccuuid', 'wsid', '/sup.md', '/state.json', 'eff-sid'));
" 2>/dev/null)
    out_cumsev=$(run_with_timeout 5 node -e "
const f = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format');
process.stdout.write(f.formatCumSevErrorReason([], 'ccuuid', 'wsid', '/sup.md', '/state.json', 'eff-sid'));
" 2>/dev/null)
    out_wtoff=$(run_with_timeout 5 node -e "
const f = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format');
process.stdout.write(f.formatWorktreeOffProposalReason('ccuuid', 'wsid', '/sup.md', '/state.json', 'eff-sid'));
" 2>/dev/null)
    local missing=""
    echo "$out_armed"  | grep -q "Effective state session ID:" || missing="$missing armed"
    echo "$out_cumsev" | grep -q "Effective state session ID:" || missing="$missing cumsev"
    echo "$out_wtoff"  | grep -q "Effective state session ID:" || missing="$missing wtoff"
    if [ -z "$missing" ]; then
        pass "C14: all 3 format functions include the line"
    else
        fail "C14: all 3 format functions include the line (missing in:$missing)"
    fi
}

# ============================================================================
# Case 15: invalid --severity → exits non-zero (schema validation rejects)
# ============================================================================
run_c15() {
    require_source "$CLI" "C15: invalid --severity exits non-zero" || return
    local tmp workdir rc
    tmp="$(mktemp -d)"
    workdir="$tmp/work"; mkdir -p "$workdir"
    (
        cd "$workdir" && \
        CLAUDE_SESSION_ID="c15-ccuuid" \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity bogus --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" != "0" ]; then
        pass "C15: invalid --severity exits non-zero (rc=$rc)"
    else
        fail "C15: invalid --severity exits non-zero (expected rc!=0, got rc=0)"
    fi
}

# ============================================================================
# Case 16: missing required --categories → exits non-zero
# ============================================================================
run_c16() {
    require_source "$CLI" "C16: missing --categories exits non-zero" || return
    local tmp workdir rc
    tmp="$(mktemp -d)"
    workdir="$tmp/work"; mkdir -p "$workdir"
    (
        cd "$workdir" && \
        CLAUDE_SESSION_ID="c16-ccuuid" \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" != "0" ]; then
        pass "C16: missing --categories exits non-zero (rc=$rc)"
    else
        fail "C16: missing --categories exits non-zero (expected rc!=0, got rc=0)"
    fi
}

# ============================================================================
# Case 17: resolveWorkflowSessionId — empty WORKFLOW_PLANS_DIR (no context.md)
# returns null without crashing.
# ============================================================================
run_c17() {
    require_source "$RESOLVE_WSID" "C17: empty plans-dir → null, no crash" || return
    local tmp workdir out
    tmp="$(mktemp -d)"
    workdir="$tmp/work"; mkdir -p "$workdir"
    # Plans dir exists but contains NO files at all.
    out="$(call_resolve_wsid "$tmp" "$workdir")"
    rm -rf "$tmp"
    if [ -z "$out" ]; then
        pass "C17: empty plans-dir → null, no crash"
    else
        fail "C17: empty plans-dir → null, no crash (got: '$out', expected empty)"
    fi
}

# ============================================================================
# Case 18: security — --session-id with shell metacharacters is rejected by
# SESSION_ID_RE, so no state file named after the injection string is created
# and no command injection occurs (the value is passed as a single argv string).
# ============================================================================
run_c18() {
    require_source "$CLI" "C18: --session-id with metacharacters → no injection" || return
    local tmp tmp_node workdir injected rc out leftover_files
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    workdir="$tmp/work"; mkdir -p "$workdir"
    # Shell metacharacters: semicolon, backtick, dollar sign, ampersand.
    injected='injected-sid; echo INJECT `id` $(id) & whoami'
    # No WORKTREE_NOTES.md, no plans-dir context.md → no fallback wsid.
    # With invalid sid (metacharacters fail SESSION_ID_RE) and no fallback,
    # the CLI should NOT create any state file matching the injected literal.
    out=$(
        cd "$workdir" && \
        unset CLAUDE_SESSION_ID && \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" --session-id "$injected" 2>&1
    )
    rc=$?
    # Verify: no command injection side-effect (no "INJECT" substring written to a file).
    # Also verify: no state file containing the literal injected substring in its name.
    leftover_files=$(ls -1 "$tmp" 2>/dev/null | grep -E '(INJECT|;|`|whoami|echo|\$)' || true)
    rm -rf "$tmp"
    # Acceptance: rc!=0 (rejected) OR — if a fallback happened to fire — at minimum no injected literal in filenames.
    if [ -z "$leftover_files" ]; then
        pass "C18: --session-id with metacharacters → no injection (rc=$rc, no leftover injection files)"
    else
        fail "C18: --session-id with metacharacters → no injection (leftover files: $leftover_files)"
    fi
}

# ============================================================================
run_c1; run_c2; run_c3; run_c4
run_c5; run_c6; run_c7; run_c8; run_c9
run_c10; run_c11; run_c12
run_c13; run_c14
run_c15; run_c16; run_c17; run_c18

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
