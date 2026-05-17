#!/bin/bash
# Tests for issue #325 — bin/github-issues/check-phase1-complete.sh
#
# Verifies that Phase 1 (sentinel posted AND history entry recorded) is
# complete before /commit-push allows merge. Pre-flight guard.
#
# RED: this suite fails clean while the script + shared lib are missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-triage-lib.sh"
CHECK_SCRIPT="$AGENTS_DIR/bin/github-issues/check-phase1-complete.sh"
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
[ -f "$LIB_SCRIPT" ]   || missing+=("bin/github-issues/issue-close-triage-lib.sh")
[ -f "$CHECK_SCRIPT" ] || missing+=("bin/github-issues/check-phase1-complete.sh")
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

# Helper: run check-phase1-complete.sh in $TMP and capture stderr.
# check_history_entry reads docs/history.md relative to CWD.
run_check() {
    local scenario="$1" n="${2:-42}"
    local rc out
    out=$(cd "$TMP" && GH_MOCK_SCENARIO="$scenario" run_with_timeout 15 bash "$CHECK_SCRIPT" "$n" 2>&1)
    rc=$?
    CHECK_STDERR="$out"
    return $rc
}

# ============================================================================
# C-series — check-phase1-complete.sh
# ============================================================================

# --- C1: sentinel=pending + history present + git log hit → exit 0
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'
### #42: Staged (2026-05-10, abc1234)
EOF
GIT_MOCK_HISTORY_COMMIT_N=42 run_check open_with_pending 42; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "C1: pending + history + git-log → exit 0"
else
    fail "C1: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# --- C2: sentinel=appended + history present → exit 0
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'
### #42: Staged (2026-05-10, abc1234)
EOF
GIT_MOCK_HISTORY_COMMIT_N=42 run_check open_with_appended 42; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "C2: appended + history → exit 0"
else
    fail "C2: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# --- C3: sentinel present + no history → exit 1 (history entry missing)
setup_tmp
# history.md intentionally empty
run_check open_with_pending 42; RC=$?
if [ "$RC" -ne 0 ] && echo "$CHECK_STDERR" | grep -qi "history"; then
    pass "C3: sentinel + no history → exit 1 (history entry missing)"
else
    fail "C3: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# --- C4: no sentinel + history present → exit 1 (sentinel missing)
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'
### #42: Staged (2026-05-10, abc1234)
EOF
GIT_MOCK_HISTORY_COMMIT_N=42 run_check issue_task 42; RC=$?
if [ "$RC" -ne 0 ] && echo "$CHECK_STDERR" | grep -qi "sentinel"; then
    pass "C4: no sentinel + history → exit 1 (sentinel missing)"
else
    fail "C4: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# --- C5: neither sentinel nor history → exit 1 (Phase 1 not started)
setup_tmp
run_check issue_task 42; RC=$?
if [ "$RC" -ne 0 ] && echo "$CHECK_STDERR" | grep -qi "Phase 1"; then
    pass "C5: neither sentinel nor history → exit 1 (Phase 1 not started)"
else
    fail "C5: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# --- C6: archived history in docs/history/YYYY.md + sentinel → exit 0
setup_tmp
mkdir -p "$TMP/docs/history"
cat >> "$TMP/docs/history/2025.md" <<'EOF'
### #42: Archived (2025-12-01, abc1234)
EOF
GIT_MOCK_HISTORY_COMMIT_N=42 run_check open_with_pending 42; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "C6: archived history + sentinel → exit 0"
else
    fail "C6: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# --- C7: non-numeric N → exit 1, no shell injection
setup_tmp
run_check issue_task "42; touch /tmp/C7_INJECT"; RC=$?
if [ "$RC" -ne 0 ] && [ ! -f /tmp/C7_INJECT ]; then
    pass "C7: non-numeric N → exit 1"
else
    fail "C7: rc=$RC inject=$([ -f /tmp/C7_INJECT ] && echo yes || echo no)"
    rm -f /tmp/C7_INJECT 2>/dev/null
fi
teardown_tmp

# --- C8: AGENTS_CONFIG_DIR unset → exit 1
setup_tmp
unset AGENTS_CONFIG_DIR
GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$CHECK_SCRIPT" 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "C8: AGENTS_CONFIG_DIR unset → exit 1"
else
    fail "C8: rc=$RC"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
