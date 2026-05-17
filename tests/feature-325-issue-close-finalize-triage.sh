#!/bin/bash
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
#   FT4: CLOSED + appended     → resume_j, J
#   FT5: CLOSED + no sentinel  → auto_close_path, B,E,G,J
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

# --- FT2: OPEN + pending → resume_e (E,F,G,H,J)
setup_tmp
run_triage open_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_e" ] && [ "$T_NEXT_STEPS" = "E,F,G,H,J" ]; then
    pass "FT2: OPEN:pending → resume_e (E,F,G,H,J)"
else
    fail "FT2: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT3: OPEN + appended → resume_h (G,H,J)
setup_tmp
run_triage open_with_appended
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_h" ] && [ "$T_NEXT_STEPS" = "G,H,J" ]; then
    pass "FT3: OPEN:appended → resume_h (G,H,J)"
else
    fail "FT3: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT4: CLOSED + appended → resume_j (J)
setup_tmp
run_triage closed_with_appended_sentinel
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_j" ] && [ "$T_NEXT_STEPS" = "J" ]; then
    pass "FT4: CLOSED:appended → resume_j (J)"
else
    fail "FT4: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT5: CLOSED + no sentinel → auto_close_path (B,E,G,J)
setup_tmp
run_triage closed_no_sentinel
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "auto_close_path" ] && [ "$T_NEXT_STEPS" = "B,E,G,J" ]; then
    pass "FT5: CLOSED:(none) → auto_close_path (B,E,G,J)"
else
    fail "FT5: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT6: CLOSED + pending + history present → stuck_sentinel_only (J)
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### #42: Already documented (2026-05-10, abc1234)
Background: x
Changes: y
EOF
run_triage closed_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "stuck_sentinel_only" ] && [ "$T_NEXT_STEPS" = "J" ]; then
    pass "FT6: CLOSED:pending + history → stuck_sentinel_only (J)"
else
    fail "FT6: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- FT7: CLOSED + pending + no history → stuck_append_sentinel (E,J)
setup_tmp
# history.md intentionally empty
run_triage closed_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "stuck_append_sentinel" ] && [ "$T_NEXT_STEPS" = "E,J" ]; then
    pass "FT7: CLOSED:pending + no history → stuck_append_sentinel (E,J)"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
