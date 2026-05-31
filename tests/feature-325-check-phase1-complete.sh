#!/bin/bash
# Tests: bin/github-issues/check-phase1-complete.sh, bin/github-issues/issue-close-triage-lib.sh
# Tags: 325, check-phase1-complete
# Tests for issue #325 — bin/github-issues/check-phase1-complete.sh
#
# Verifies that Phase 1 (sentinel posted) is complete before /commit-push
# allows merge. Pre-flight guard.
#
# After issue #325, Phase 1 no longer writes docs/history.md (that work
# moved to Phase 2). The only Phase 1 completion signal is the sentinel —
# the previous "sentinel AND history entry" gate collapsed to sentinel-only.
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
run_check() {
    local scenario="$1" n="${2:-42}"
    local rc out
    out=$(cd "$TMP" && GH_MOCK_SCENARIO="$scenario" run_with_timeout 15 bash "$CHECK_SCRIPT" "$n" 2>&1)
    rc=$?
    CHECK_STDERR="$out"
    return $rc
}

# ============================================================================
# C-series — check-phase1-complete.sh (sentinel-only gate after #325)
# ============================================================================

# --- C1: sentinel=pending → exit 0 (history.md no longer checked)
setup_tmp
# history.md intentionally empty — Phase 1 no longer writes it.
run_check open_with_pending 42; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "C1: pending sentinel alone → exit 0 (no history.md check)"
else
    fail "C1: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# --- C2: sentinel=appended → exit 0
setup_tmp
# history.md intentionally empty.
run_check open_with_appended 42; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "C2: appended sentinel alone → exit 0"
else
    fail "C2: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# (Pre-#325 C3 / C4 — which asserted failure when sentinel was present but
# history entry was missing, or vice versa — were removed. Phase 1 no longer
# writes history.md, so the sentinel alone is the canonical completion
# signal; pairing tests against history.md state are no longer meaningful.)

# --- C5: no sentinel → exit 1 (Phase 1 not started)
setup_tmp
run_check issue_task 42; RC=$?
if [ "$RC" -ne 0 ] && echo "$CHECK_STDERR" | grep -qi "Phase 1"; then
    pass "C5: no sentinel → exit 1 (Phase 1 not started)"
else
    fail "C5: rc=$RC stderr=$CHECK_STDERR"
fi
teardown_tmp

# (Pre-#325 C6 — archived history in docs/history/YYYY.md — was removed.
# Phase 1 no longer reads history.md or its archives.)

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
