#!/bin/bash
# tests/feature-883-resolve-workflow-session-id.sh
# Tests: hooks/lib/resolve-workflow-session-id.js, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, session-id, workflow-state, layer2, scope:issue-specific
# RED for issue #883.
# L3 gap (what this test does NOT catch):
# - tests invoke resolveWorkflowSessionId() directly via node -e rather than
#   exercising the full Stop hook (supervisor-guard.js); end-to-end wiring of the
#   resolver into the block-reason injection path is covered by G20/G21 in
#   feature-719-supervisor-guard-hook.sh, not here.
# - real ~/.workflow-plans/ directory layout differences — tests use temp dirs,
#   so OS-specific quirks (e.g. SMB share mtime resolution) are not exercised.
# Closest-to-action mitigation: hook-registration / skill-orchestration categories
#   in bin/check-verification-gate.sh fire at WORKFLOW_USER_VERIFIED preflight
#   when supervisor-guard.js / workflow-state.js changes are staged.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

RESOLVE_WSID_NODE="$_AGENTS_DIR_NODE/hooks/lib/resolve-workflow-session-id.js"
SUPERVISOR_STATE_WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_function() {
    local fn="$1" label="$2"
    node -e "const m=require('$RESOLVE_WSID_NODE'); if(typeof m['$fn']!=='function') process.exit(1);" 2>/dev/null
    if [ $? -ne 0 ]; then skip "$label (resolveWorkflowSessionId not implemented yet)"; return 1; fi
    return 0
}

# Today's local date as YYYYMMDD (used by date-sanity guard).
TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
YESTERDAY=$(node -e "const d=new Date(Date.now()-86400000); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)

# Invoke resolveWorkflowSessionId({}) with WORKFLOW_PLANS_DIR=$1, (optional) CLAUDE_ENV_FILE=$2,
# and (optional) work_dir=$3 (defaults to $1). process.cwd() is set to work_dir so Priority 1
# (WORKTREE_NOTES.md) can be controlled per-test without interference from the repo CWD.
# Stdout: 'NULL' or the resolved sid.
call_resolve() {
    local plans_dir="$1" env_file="${2:-}" work_dir="${3:-$1}"
    if [ -n "$env_file" ]; then
        (cd "$work_dir" && WORKFLOW_PLANS_DIR="$plans_dir" CLAUDE_ENV_FILE="$env_file" \
            run_with_timeout 5 env -u CLAUDE_CODE_SESSION_ID node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null)
    else
        # Explicitly unset CLAUDE_ENV_FILE and CLAUDE_CODE_SESSION_ID so leaked env
        # vars from the host shell cannot influence the test outcome.
        (cd "$work_dir" && WORKFLOW_PLANS_DIR="$plans_dir" \
            run_with_timeout 5 env -u CLAUDE_ENV_FILE -u CLAUDE_CODE_SESSION_ID node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null)
    fi
}

# Variant of call_resolve that injects CLAUDE_CODE_SESSION_ID explicitly.
call_resolve_with_code_sid() {
    local plans_dir="$1" code_sid="$2" work_dir="${3:-$1}"
    (cd "$work_dir" && WORKFLOW_PLANS_DIR="$plans_dir" CLAUDE_CODE_SESSION_ID="$code_sid" \
        run_with_timeout 5 env -u CLAUDE_ENV_FILE node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null)
}

# Set mtime on a list of files: pairs of (path, offset-seconds-from-now).
set_mtimes() {
    # Args: path1 offset1 path2 offset2 ...
    node -e "
const fs = require('fs');
const args = process.argv.slice(1);
const now = Date.now() / 1000;
for (let i = 0; i < args.length; i += 2) {
    const p = args[i];
    const off = parseFloat(args[i+1]);
    const t = now + off;
    fs.utimesSync(p, t, t);
}
" -- "$@" 2>/dev/null
}

run_r0() {
    require_function "resolveWorkflowSessionId" "R0: WORKTREE_NOTES.md Session-ID takes priority" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Priority 1: WORKTREE_NOTES.md in CWD with a valid session ID.
    # Also add a context.md with a different id to confirm it is NOT picked.
    printf "Session-ID: %s-r0session\n" "$TODAY" > "$tmp/WORKTREE_NOTES.md"
    : > "$tmp/${TODAY}-other-context.md"
    out=$(call_resolve "$tmp" "" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-r0session" ]; then
        pass "R0: WORKTREE_NOTES.md Session-ID takes priority"
    else
        fail "R0: WORKTREE_NOTES.md Session-ID takes priority (out=$out)"
    fi
}

run_r0b() {
    require_function "resolveWorkflowSessionId" "R0b: WORKTREE_NOTES.md via git common-dir (linked worktree)" || return
    if ! command -v git >/dev/null 2>&1; then skip "R0b: git not available"; return; fi
    local main_repo linked_wt plans_tmp out sid
    main_repo="$(mktemp -d)"
    linked_wt="${main_repo}/linked-wt"
    plans_tmp="$(mktemp -d)"
    sid="${TODAY}-r0bsession"
    # Set up a minimal git repo with one commit so git worktree add works.
    (cd "$main_repo" && git init -q && git config user.email "test@example.com" && \
        git config user.name "Test" && git commit -q --allow-empty -m "init") 2>/dev/null
    # Create linked worktree — no WORKTREE_NOTES.md there.
    (cd "$main_repo" && git worktree add -q "$linked_wt" -b "test-r0b") 2>/dev/null
    # WORKTREE_NOTES.md in main repo root (git common-dir parent).
    printf "Session-ID: %s\n" "$sid" > "$main_repo/WORKTREE_NOTES.md"
    # Run from linked worktree: CWD has no WORKTREE_NOTES.md; common-dir parent does.
    out=$(call_resolve "$plans_tmp" "" "$linked_wt")
    rm -rf "$main_repo" "$plans_tmp"
    if [ "$out" = "$sid" ]; then
        pass "R0b: WORKTREE_NOTES.md via git common-dir (linked worktree)"
    else
        fail "R0b: WORKTREE_NOTES.md via git common-dir (linked worktree) (out=$out)"
    fi
}

run_r1() {
    require_function "resolveWorkflowSessionId" "R1: env+intent happy path" || return
    local tmp out envfile
    tmp="$(mktemp -d)"
    envfile="$tmp/claude.env"
    echo "CLAUDE_SESSION_ID=cc-uuid" > "$envfile"
    : > "$tmp/cc-uuid-intent.md"
    out=$(call_resolve "$tmp" "$envfile")
    rm -rf "$tmp"
    if [ "$out" = "cc-uuid" ]; then
        pass "R1: env+intent happy path"
    else
        fail "R1: env+intent happy path (out=$out)"
    fi
}

run_r2() {
    require_function "resolveWorkflowSessionId" "R2: env present but no intent.md, 2 stubs (no ccBucket=0) -> NULL" || return
    local tmp out envfile
    tmp="$(mktemp -d)"
    envfile="$tmp/claude.env"
    echo "CLAUDE_SESSION_ID=cc-uuid" > "$envfile"
    # NOTE: no cc-uuid-intent.md — force fallthrough to mtime scan.
    # Both stubs have ccBucket=1 (cc-uuid not in context.md content); gate fires → NULL.
    : > "$tmp/${TODAY}-early-context.md"
    : > "$tmp/${TODAY}-later-context.md"
    set_mtimes "$tmp/${TODAY}-early-context.md" -4 "$tmp/${TODAY}-later-context.md" -2
    out=$(call_resolve "$tmp" "$envfile")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R2: env present but no intent.md, 2 stubs (no ccBucket=0) -> NULL"
    else
        fail "R2: env present but no intent.md, 2 stubs (no ccBucket=0) -> NULL (out=$out)"
    fi
}

run_r3() {
    require_function "resolveWorkflowSessionId" "R3: single same-day context.md" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-001252-context.md"
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-001252" ]; then
        pass "R3: single same-day context.md"
    else
        fail "R3: single same-day context.md (out=$out)"
    fi
}

run_r4() {
    require_function "resolveWorkflowSessionId" "R4: 3 same-day stubs, no env (no ccBucket=0) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-a-context.md"
    : > "$tmp/${TODAY}-b-context.md"
    : > "$tmp/${TODAY}-c-context.md"
    # b is newest (T-2); a is T-6; c is T-4. All ccBucket=1 (no env). Gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-a-context.md" -6 \
        "$tmp/${TODAY}-b-context.md" -2 \
        "$tmp/${TODAY}-c-context.md" -4
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R4: 3 same-day stubs, no env (no ccBucket=0) -> NULL"
    else
        fail "R4: 3 same-day stubs, no env (no ccBucket=0) -> NULL (out=$out)"
    fi
}

run_r5() {
    require_function "resolveWorkflowSessionId" "R5: empty plans-dir -> null" || return
    local tmp out
    tmp="$(mktemp -d)"
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R5: empty plans-dir -> null"
    else
        fail "R5: empty plans-dir -> null (out=$out)"
    fi
}

run_r6() {
    require_function "resolveWorkflowSessionId" "R6: nonexistent plans-dir -> null (no throw)" || return
    local tmp out bogus
    tmp="$(mktemp -d)"
    bogus="$tmp/does-not-exist"
    # work_dir=$tmp (exists) so cd succeeds; plans_dir=bogus so readdirSync returns null.
    out=$(call_resolve "$bogus" "" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R6: nonexistent plans-dir -> null (no throw)"
    else
        fail "R6: nonexistent plans-dir -> null (no throw) (out=$out)"
    fi
}

run_r7() {
    require_function "resolveWorkflowSessionId" "R7: adversarial filename blocked by charset validator" || return
    local tmp out
    tmp="$(mktemp -d)"
    # '..' has dots — fails /^[A-Za-z0-9_-]+$/. Must NOT be returned.
    : > "$tmp/..-context.md"
    : > "$tmp/${TODAY}-good-context.md"
    set_mtimes \
        "$tmp/..-context.md" -2 \
        "$tmp/${TODAY}-good-context.md" -4
    # Note: even though '..' has newer mtime, the charset validator should drop it,
    # leaving only ${TODAY}-good as a valid candidate.
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-good" ]; then
        pass "R7: adversarial filename blocked by charset validator"
    else
        fail "R7: adversarial filename blocked by charset validator (out=$out)"
    fi
}

run_r8() {
    require_function "resolveWorkflowSessionId" "R8: date-sanity excludes yesterday; 2 today stubs (no ccBucket=0) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-090000-context.md"
    : > "$tmp/${TODAY}-100000-context.md"
    : > "$tmp/${YESTERDAY}-235959-context.md"
    # Yesterday file excluded by date-sanity guard. 2 today stubs remain; both ccBucket=1 (no env). Gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-090000-context.md" -6 \
        "$tmp/${TODAY}-100000-context.md" -4 \
        "$tmp/${YESTERDAY}-235959-context.md" -2
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R8: date-sanity excludes yesterday; 2 today stubs (no ccBucket=0) -> NULL"
    else
        fail "R8: date-sanity excludes yesterday; 2 today stubs (no ccBucket=0) -> NULL (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# R9 / R10: depth-score tie-breaker
# Active sessions (with intent.md or detail.md) MUST beat bare-stub sessions
# (context.md only) even when the stub has the newer mtime. This is the
# Priority 3 enhancement for issue #949 / #883 follow-up.
# ---------------------------------------------------------------------------

run_r9() {
    require_function "resolveWorkflowSessionId" "R9: active+stub, no env (both ccBucket=1) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    # 'active' has context+intent+detail (depth=2), older mtime T-10.
    : > "$tmp/${TODAY}-active-context.md"
    : > "$tmp/${TODAY}-active-intent.md"
    : > "$tmp/${TODAY}-active-detail.md"
    # 'stub' has context.md only (depth=0), newer mtime T-2.
    : > "$tmp/${TODAY}-stub-context.md"
    # Both ccBucket=1 (no env): gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-active-context.md" -10 \
        "$tmp/${TODAY}-active-intent.md" -10 \
        "$tmp/${TODAY}-active-detail.md" -10 \
        "$tmp/${TODAY}-stub-context.md" -2
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R9: active+stub, no env (both ccBucket=1) -> NULL"
    else
        fail "R9: active+stub, no env (both ccBucket=1) -> NULL (out=$out)"
    fi
}

run_r10() {
    require_function "resolveWorkflowSessionId" "R10: intonly+stub, no env (both ccBucket=1) -> NULL" || return
    local tmp out
    tmp="$(mktemp -d)"
    # 'intonly' has context+intent (depth=1), older mtime T-8.
    : > "$tmp/${TODAY}-intonly-context.md"
    : > "$tmp/${TODAY}-intonly-intent.md"
    # 'stub' has context.md only (depth=0), newer mtime T-2.
    : > "$tmp/${TODAY}-stub-context.md"
    # Both ccBucket=1 (no env): gate fires → NULL.
    set_mtimes \
        "$tmp/${TODAY}-intonly-context.md" -8 \
        "$tmp/${TODAY}-intonly-intent.md" -8 \
        "$tmp/${TODAY}-stub-context.md" -2
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R10: intonly+stub, no env (both ccBucket=1) -> NULL"
    else
        fail "R10: intonly+stub, no env (both ccBucket=1) -> NULL (out=$out)"
    fi
}

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
    echo '{}' > "$tmp/${TODAY}-active-r11-final-report-env.json"
    set_mtimes \
        "$tmp/${TODAY}-active-r11-context.md" -10 \
        "$tmp/${TODAY}-active-r11-intent.md" -10 \
        "$tmp/${TODAY}-active-r11-detail.md" -10 \
        "$tmp/${TODAY}-stub-r11-context.md" -2

    # Run ensureAlertScheduled with CWD = tmp (no WORKTREE_NOTES.md there ->
    # resolver falls through Priority 1 -> Priority 3 depth-scan). The stub cc
    # sid validates against SESSION_ID_RE but has no final-report-env.json;
    # only the resolver-found active sid carries the final-report-env marker.
    armed_at_out=$(cd "$tmp" && WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 env -u CLAUDE_ENV_FILE node -e "
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
    out=$(call_resolve "$tmp" "" "$tmp")
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

run_r14() {
    require_function "resolveWorkflowSessionId" "R14: CLAUDE_SESSION_ID invalid charset falls through to P3" || return
    local tmp envfile out
    tmp="$(mktemp -d)"
    envfile="$tmp/test.env"
    # Contains '!' which fails /^[A-Za-z0-9_-]+$/ → P2 skips, P3 scans.
    printf "CLAUDE_SESSION_ID=%s!invalid\n" "$TODAY" > "$envfile"
    : > "$tmp/${TODAY}r14active-context.md"
    : > "$tmp/${TODAY}r14active-intent.md"
    out=$(call_resolve "$tmp" "$envfile" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}r14active" ]; then
        pass "R14: CLAUDE_SESSION_ID invalid charset falls through to P3"
    else
        fail "R14: CLAUDE_SESSION_ID invalid charset falls through to P3 (out=$out)"
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
    out=$(call_resolve "$tmp" "" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}r16active" ]; then
        pass "R16: whitespace-only Session-ID (P1 falls through to P3)"
    else
        fail "R16: whitespace-only Session-ID fallthrough (out=$out)"
    fi
}

run_r0
run_r0b
run_r1
run_r2
run_r3
run_r4
run_r5
run_r6
run_r7
run_r8
run_r9
run_r10
run_r11
run_r12
run_r13
run_r14
run_r15
run_r16

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
    out=$(call_resolve "$tmp" "" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R19: CLAUDE_CODE_SESSION_ID unset, active+stub, no env (both ccBucket=1) -> NULL"
    else
        fail "R19: CLAUDE_CODE_SESSION_ID unset, both ccBucket=1 -> NULL (out=$out)"
    fi
}

run_r17
run_r18
run_r19

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

run_r20
run_r21

# ---------------------------------------------------------------------------
# R22: multiple candidates, one ccBucket=0 -> gate NOT fired -> ccBucket=0 wins.
# Gate: !candidates.some(c=>c.ccBucket===0) && candidates.length > 1.
# When owner context.md has CC UUID, ccBucket=0 -> !some() is FALSE -> dormant.
# Validates gate does NOT over-fire when ccBucket=0 is present.
# ---------------------------------------------------------------------------

run_r22() {
    require_function "resolveWorkflowSessionId" "R22: multiple candidates, one ccBucket=0 -> gate dormant -> ccBucket=0 wins" || return
    local tmp out envfile ccuuid
    tmp="$(mktemp -d)"
    envfile="$tmp/claude.env"
    ccuuid="r22-ccuuid"
    echo "CLAUDE_SESSION_ID=$ccuuid" > "$envfile"
    # Owner: context.md has CC UUID -> ccBucket=0.
    printf "Session-ID: %s\n%s\n" "${TODAY}-r22owner" "$ccuuid" > "$tmp/${TODAY}-r22owner-context.md"
    # Foreign: empty context.md -> ccBucket=1; newer mtime still loses ccBucket sort.
    : > "$tmp/${TODAY}-r22foreign-context.md"
    set_mtimes \
        "$tmp/${TODAY}-r22owner-context.md" -10 \
        "$tmp/${TODAY}-r22foreign-context.md" -2
    out=$(call_resolve "$tmp" "$envfile")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-r22owner" ]; then
        pass "R22: multiple candidates, one ccBucket=0 -> gate dormant -> ccBucket=0 wins"
    else
        fail "R22: multiple candidates, one ccBucket=0 -> gate dormant -> ccBucket=0 wins (out=$out, expected ${TODAY}-r22owner)"
    fi
}

run_r22

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
