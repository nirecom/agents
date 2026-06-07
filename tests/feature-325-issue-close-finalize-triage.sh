#!/bin/bash
# Tests: bin/github-issues/issue-close-finalize-triage.sh, bin/github-issues/issue-close-triage-lib.sh, bin/github-issues/issue-close-triage.sh
# Tags: issue-close, stage, workflow, finalize, triage
# Tests for issue #325 — /issue-close-finalize skill triage script.
#
# Phase 2 (`/issue-close-finalize`) runs from main worktree AFTER PR merge.
# Steps H,J. API-only (no docs writes; doc-append happened in Phase 1).
#
# This script is a rename of bin/github-issues/issue-close-triage.sh with
# one key behavior change: OPEN:(none) is now an ERROR (Phase 1 must run
# first), instead of "proceed".
#
# Routing scenarios for issue-close-finalize-triage.sh:
#   FT1: OPEN + no sentinel    → error (mentions /issue-close-stage) ← NEW
#   FT2: OPEN + pending        → resume_e, E,F,G,H,J  (recovery for stuck)
#   FT3: OPEN + appended       → resume_h, G,H,J
#   FT4: CLOSED + appended     → resume_j, E,J,K    (E added: #412 History Notes write)
#   FT5: CLOSED + no sentinel  → auto_close_path, E,G,J
#   FT6: CLOSED + pending + hist → stuck_sentinel_only, J
#   FT7: CLOSED + pending + no hist → stuck_append_sentinel, E,J
#   FT8: non-numeric N         → error
#   FT9: AGENTS_CONFIG_DIR unset → error
#
# RED: this suite fails clean while the script + shared lib are missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-triage-lib.sh"
FINALIZE_TRIAGE_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-finalize-triage.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
missing=()
[ -f "$LIB_SCRIPT" ]              || missing+=("bin/github-issues/issue-close-triage-lib.sh")
[ -f "$FINALIZE_TRIAGE_SCRIPT" ]  || missing+=("bin/github-issues/issue-close-finalize-triage.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/docs/history"
    : > "$TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR
    unset GH_MOCK_COMMENT_LOG
}

# Helper: run finalize triage; capture STATE/SENTINEL/ACTION/NEXT_STEPS.
# cd into $TMP because check_history_entry reads docs/history.md relative
# to CWD.
run_triage() {
    local scenario="$1"
    unset STATE SENTINEL ACTION NEXT_STEPS
    local out
    if out=$(cd "$TMP" && GH_MOCK_SCENARIO="$scenario" run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/dev/null); then
        T_RC=0
    else
        T_RC=$?
    fi
    # shellcheck disable=SC1090
    eval "$out" 2>/dev/null
    T_STATE="${STATE:-}"
    T_SENTINEL="${SENTINEL:-}"
    T_ACTION="${ACTION:-}"
    T_NEXT_STEPS="${NEXT_STEPS:-}"
}

# ============================================================================
# FT-series — finalize triage routing
# ============================================================================

# --- FT1: OPEN + no sentinel → non-zero exit + stderr mentions /issue-close-stage
# This is THE KEY behavior change vs. old issue-close-triage.sh.
setup_tmp
GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/tmp/ft1_err.$$ >/dev/null
RC=$?
FT1_ERR=$(cat /tmp/ft1_err.$$); rm -f /tmp/ft1_err.$$
if [ "$RC" -ne 0 ] && echo "$FT1_ERR" | grep -qi "issue-close-stage"; then
    pass "FT1: OPEN:(none) → non-zero exit + stderr mentions /issue-close-stage"
else
    fail "FT1: rc=$RC stderr=$FT1_ERR"
fi
teardown_tmp

# --- FT2: OPEN + pending → resume_e (F,G,H,J,K)
# #690: Step E (doc-append) removed from NEXT_STEPS — docs/history.md now written
# by /worktree-end Step 6h from WORKTREE_NOTES.md.
setup_tmp
run_triage open_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_e" ] && [ "$T_NEXT_STEPS" = "F,G,H,J,K" ]; then
    pass "FT2: OPEN:pending → resume_e (F,G,H,J,K)"
else
    fail "FT2: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT3: OPEN + appended → resume_h (G,H,J,K)
setup_tmp
run_triage open_with_appended
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_h" ] && [ "$T_NEXT_STEPS" = "G,H,J,K" ]; then
    pass "FT3: OPEN:appended → resume_h (G,H,J,K)"
else
    fail "FT3: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT4: CLOSED + appended → resume_j (J,K)
# #690: Step E removed.
setup_tmp
run_triage closed_with_appended_sentinel
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_j" ] && [ "$T_NEXT_STEPS" = "J,K" ]; then
    pass "FT4: CLOSED:appended → resume_j (J,K)"
else
    fail "FT4: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT5: CLOSED + no sentinel → auto_close_path (G,J,K)
# Bug #366: previously asserted B,E,G,J. Step B removed (#366); Step E removed (#690).
# auto_close_path: issue already CLOSED; gating on open sub-issues is moot.
setup_tmp
run_triage closed_no_sentinel
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "auto_close_path" ] && [ "$T_NEXT_STEPS" = "G,J,K" ]; then
    pass "FT5: CLOSED:(none) → auto_close_path (G,J,K)"
else
    fail "FT5: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT5b: CLOSED + no sentinel + open sub-issue → auto_close_path (G,J,K)
# Regression trap for bug #366. If B or E reappear in NEXT_STEPS, this test fails.
setup_tmp
run_triage closed_no_sentinel_open_subissue
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "auto_close_path" ] && [ "$T_NEXT_STEPS" = "G,J,K" ]; then
    pass "FT5b: CLOSED:(none) + open sub-issue → auto_close_path (G,J,K), no Step B or E"
else
    fail "FT5b: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT6: CLOSED + pending + history present → stuck_sentinel_only (J,K)
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### #42: Already documented (2026-05-10, abc1234)
Background: x
Changes: y
EOF
run_triage closed_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "stuck_sentinel_only" ] && [ "$T_NEXT_STEPS" = "J,K" ]; then
    pass "FT6: CLOSED:pending + history → stuck_sentinel_only (J,K)"
else
    fail "FT6: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT7: CLOSED + pending + no history → stuck_sentinel_only (J,K)
# #690: stuck_append_sentinel action removed; triage routes all CLOSED:pending to
# stuck_sentinel_only (J,K) regardless of history.md state.
setup_tmp
# history.md intentionally empty
run_triage closed_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "stuck_sentinel_only" ] && [ "$T_NEXT_STEPS" = "J,K" ]; then
    pass "FT7: CLOSED:pending + no history → stuck_sentinel_only (J,K)"
else
    fail "FT7: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT8: non-numeric N → non-zero, no shell injection
setup_tmp
GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" "42; touch /tmp/FT8_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f /tmp/FT8_INJECT ]; then
    pass "FT8: non-numeric N rejected, no shell injection"
else
    fail "FT8: rc=$RC inject=$([ -f /tmp/FT8_INJECT ] && echo yes || echo no)"
    rm -f /tmp/FT8_INJECT 2>/dev/null
fi
teardown_tmp

# --- FT9: AGENTS_CONFIG_DIR unset → non-zero
setup_tmp
unset AGENTS_CONFIG_DIR
GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "FT9: AGENTS_CONFIG_DIR unset → non-zero"
else
    fail "FT9: rc=$RC"
fi
teardown_tmp

# --- FT10: OPEN + stale pending → auto-expired → same as OPEN:(none) → error
setup_tmp
GH_MOCK_SCENARIO=open_with_stale_pending \
    run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/tmp/ft10_err.$$ >/dev/null
RC=$?
FT10_ERR=$(cat /tmp/ft10_err.$$); rm -f /tmp/ft10_err.$$
if [ "$RC" -ne 0 ] && echo "$FT10_ERR" | grep -qi "auto-expired\|issue-close-stage"; then
    pass "FT10: OPEN + stale pending → auto-expired → error mentions issue-close-stage"
else
    fail "FT10: rc=$RC stderr=$FT10_ERR"
fi
teardown_tmp

# --- FT11: CLOSED + stale pending → auto-expired → auto_close_path (G,J,K)
# #690: Step E removed from auto_close_path NEXT_STEPS.
setup_tmp
run_triage closed_with_stale_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "auto_close_path" ] && [ "$T_NEXT_STEPS" = "G,J,K" ]; then
    pass "FT11: CLOSED + stale pending → auto-expired → auto_close_path (G,J,K)"
else
    fail "FT11: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT12: OPEN + fresh appended → unaffected (resume_h)
setup_tmp
run_triage open_with_appended
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_h" ] && [ "$T_NEXT_STEPS" = "G,H,J,K" ]; then
    pass "FT12: OPEN + fresh appended → fresh, unaffected → resume_h (G,H,J,K)"
else
    fail "FT12: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT13: ISSUE_CLOSE_STALE_DAYS=999 → even 35-day-old sentinel is fresh
setup_tmp
# Re-run capturing full output to distinguish "stale expired" from "pending resume"
TMP_OUT=$(cd "$TMP" && ISSUE_CLOSE_STALE_DAYS=999 GH_MOCK_SCENARIO=open_with_stale_pending \
    run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/tmp/ft13_err.$$)
FT13_RC=$?
FT13_ERR=$(cat /tmp/ft13_err.$$); rm -f /tmp/ft13_err.$$
unset STATE SENTINEL ACTION NEXT_STEPS
eval "$TMP_OUT" 2>/dev/null || true
if [ "$FT13_RC" -eq 0 ] && [ "${ACTION:-}" = "resume_e" ]; then
    pass "FT13: ISSUE_CLOSE_STALE_DAYS=999 → sentinel not expired → resume_e"
elif ! echo "$FT13_ERR" | grep -qi "auto-expired"; then
    pass "FT13: ISSUE_CLOSE_STALE_DAYS=999 → sentinel not auto-expired"
else
    fail "FT13: ISSUE_CLOSE_STALE_DAYS=999 unexpectedly expired sentinel (rc=$FT13_RC err=$FT13_ERR)"
fi
teardown_tmp

# --- FT14: malformed createdAt → fail-open → OPEN:pending → resume_e
setup_tmp
run_triage open_with_malformed_created_at
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_e" ]; then
    pass "FT14: malformed createdAt → fail-open → resume_e (OPEN:pending)"
else
    fail "FT14: rc=$T_RC action=$T_ACTION (expected resume_e for fail-open on malformed date)"
fi
teardown_tmp

# --- FT15: future createdAt → fail-open → OPEN:pending → resume_e
setup_tmp
run_triage open_with_future_created_at
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_e" ]; then
    pass "FT15: future createdAt → fail-open → resume_e (OPEN:pending)"
else
    fail "FT15: rc=$T_RC action=$T_ACTION (expected resume_e for fail-open on future date)"
fi
teardown_tmp

# --- FT16: OPEN + meta label + all sub-issues closed → admin_close_path (G,H,J,K)
# Meta-cascade admin-close path: triage detects the meta label on an OPEN
# issue with zero open sub-issues and routes to admin_close_path.
setup_tmp
run_triage meta_admin_close_path
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "admin_close_path" ] && [ "$T_NEXT_STEPS" = "G,H,J,K" ]; then
    pass "FT16: OPEN + meta + all subs closed → admin_close_path (G,H,J,K)"
else
    fail "FT16: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT17: OPEN + meta label + 1 open child → graceful leave-open (#675-B)
# Meta parents with open sub-issues must now exit 0 with ACTION=meta_pending_subs
# and empty NEXT_STEPS so /issue-close-finalize can return cleanly. The cascade
# from a child close will re-attempt parent close after the last sub-issue is
# closed; surfacing an error here just spammed the user with false alarms.
setup_tmp
FT17_OUT=$(cd "$TMP" && GH_MOCK_SCENARIO=meta_child_open run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/tmp/ft17_err.$$)
RC=$?
unset STATE SENTINEL ACTION NEXT_STEPS
# shellcheck disable=SC1090
eval "$FT17_OUT" 2>/dev/null
FT17_ERR=$(cat /tmp/ft17_err.$$); rm -f /tmp/ft17_err.$$
if [ "$RC" -eq 0 ] && [ "${ACTION:-}" = "meta_pending_subs" ] && [ -z "${NEXT_STEPS:-}" ] && echo "$FT17_ERR" | grep -qi "meta parent with open sub-issues"; then
    pass "FT17: OPEN + meta + 1 open child → graceful exit 0 + meta_pending_subs (#675)"
else
    fail "FT17: rc=$RC action=${ACTION:-} next='${NEXT_STEPS:-}' stderr=$FT17_ERR"
fi
teardown_tmp

# --- FT18: OPEN + meta label + 0 sub-issues → admin_close_path (G,H,J,K)
# Zero-children meta still qualifies: planning-only umbrella collapses cleanly
# through admin_close_path.
setup_tmp
run_triage meta_zero_children
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "admin_close_path" ] && [ "$T_NEXT_STEPS" = "G,H,J,K" ]; then
    pass "FT18: OPEN + meta + 0 sub-issues → admin_close_path (G,H,J,K)"
else
    fail "FT18: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT19: OPEN + meta label + repo view fails → error fall-through
# If owner/repo cannot be resolved, the sub-issue gate cannot run; triage
# must NOT silently fall into admin_close_path.
setup_tmp
GH_MOCK_SCENARIO=meta_no_repo run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/tmp/ft19_err.$$ >/dev/null
RC=$?
FT19_ERR=$(cat /tmp/ft19_err.$$); rm -f /tmp/ft19_err.$$
if [ "$RC" -ne 0 ]; then
    pass "FT19: OPEN + meta + repo view fails → error fall-through"
else
    fail "FT19: rc=$RC stderr=$FT19_ERR"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
