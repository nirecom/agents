#!/bin/bash
# Tests: bin/gh, bin/github-issues/parent-ancestor-reopen.sh
# Tags: github, issues, bin, tests
# Tests for bin/github-issues/parent-ancestor-reopen.sh
#
# I/F: parent-ancestor-reopen.sh <owner/repo> <N>
#   exit 0: success (including zero reopens)
#   exit 1: validation error / API failure / reopen failure aggregated
#
# RED: this suite fails clean while parent-ancestor-reopen.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/parent-ancestor-reopen.sh"

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

# Early-exit: implementation missing → report all cases as FAIL and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/parent-ancestor-reopen.sh not found (implementation missing)"
    for c in AR1 AR2 AR3 AR4 AR5 AR6 AR7 AR8 AR9; do
        echo "FAIL: $c — RED until implementation"
    done
    echo ""
    echo "Results: 0 passed, 9 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Inline gh mock factory
# ---------------------------------------------------------------------------

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    exit 0 ;;
  api\ repos/*/issues/*\ --jq*)
    # api repos/<owner>/<repo>/issues/<N> --jq .parent.number // empty
    # Extract N from the second arg's last path component.
    INUM=$(echo "$ARGS" | awk '{print $2}' | awk -F/ '{print $NF}')
    eval "ABSENT=\${GH_MOCK_PARENT_ABSENT_${INUM}:-0}"
    if [ "$ABSENT" = "1" ]; then
        echo ""
        exit 0
    fi
    eval "PNUM=\${GH_MOCK_PARENT_NUM_${INUM}:-}"
    echo "$PNUM"
    exit 0 ;;
  issue\ view\ *--json\ state*)
    # issue view <N> --json state --jq .state
    NUM=$(echo "$ARGS" | awk '{print $3}')
    eval "STATE=\${GH_MOCK_STATE_${NUM}:-OPEN}"
    echo "$STATE"
    exit 0 ;;
  issue\ reopen\ *)
    RNUM=$(echo "$ARGS" | awk '{print $3}')
    eval "RFAIL=\${GH_MOCK_REOPEN_FAIL_${RNUM}:-0}"
    if [ "$RFAIL" = "1" ]; then
        echo "error: cannot reopen issue $RNUM" >&2
        exit 1
    fi
    exit 0 ;;
  repo\ view\ *nameWithOwner*)
    echo "nirecom/agents"
    exit 0 ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    TMP=""
    # Unset mock control vars used across tests.
    local v
    for v in GH_MOCK_ARGS_LOG \
             GH_MOCK_PARENT_NUM_200 GH_MOCK_PARENT_NUM_100 GH_MOCK_PARENT_NUM_50 \
             GH_MOCK_PARENT_ABSENT_200 \
             GH_MOCK_STATE_100 GH_MOCK_STATE_50 \
             GH_MOCK_REOPEN_FAIL_100 GH_MOCK_REOPEN_FAIL_50; do
        unset "$v" 2>/dev/null || true
    done
    # AR9 chain vars
    local i
    for i in $(seq 949 1000); do
        unset "GH_MOCK_PARENT_NUM_$i" 2>/dev/null || true
        unset "GH_MOCK_STATE_$i" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# AR1: parent OPEN → reopen NOT called, exit 0
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_PARENT_NUM_200=100
export GH_MOCK_STATE_100=OPEN
run_with_timeout 30 bash "$TARGET" nirecom/agents 200 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && ! grep -q "issue reopen" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "AR1: parent OPEN → no reopen, exit 0"
else
    fail "AR1: parent OPEN should skip reopen (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# AR2: parent CLOSED → reopen #100 once, exit 0
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_PARENT_NUM_200=100
export GH_MOCK_STATE_100=CLOSED
# #100 has no parent
export GH_MOCK_PARENT_ABSENT_100=1
run_with_timeout 30 bash "$TARGET" nirecom/agents 200 >/dev/null 2>&1
RC=$?
REOPEN_COUNT=$(grep -c "issue reopen 100" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$REOPEN_COUNT" -eq 1 ]; then
    pass "AR2: parent CLOSED → reopen #100 once, exit 0"
else
    fail "AR2: expected reopen 100 once, exit 0 (rc=$RC count=$REOPEN_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
unset GH_MOCK_PARENT_ABSENT_100
teardown_mock

# ---------------------------------------------------------------------------
# AR3: 3-level CLOSED chain → reopen #100 and #50, exit 0
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_PARENT_NUM_200=100
export GH_MOCK_STATE_100=CLOSED
export GH_MOCK_PARENT_NUM_100=50
export GH_MOCK_STATE_50=CLOSED
export GH_MOCK_PARENT_ABSENT_50=1
run_with_timeout 30 bash "$TARGET" nirecom/agents 200 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -q "issue reopen 100" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q "issue reopen 50" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "AR3: 3-level CLOSED chain → reopen #100 and #50, exit 0"
else
    fail "AR3: expected reopens of 100 and 50, exit 0 (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
unset GH_MOCK_PARENT_NUM_100 GH_MOCK_PARENT_ABSENT_50
teardown_mock

# ---------------------------------------------------------------------------
# AR4: 3-level chain with grandparent OPEN → reopen only #100, exit 0
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_PARENT_NUM_200=100
export GH_MOCK_STATE_100=CLOSED
export GH_MOCK_PARENT_NUM_100=50
export GH_MOCK_STATE_50=OPEN
run_with_timeout 30 bash "$TARGET" nirecom/agents 200 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -q "issue reopen 100" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && ! grep -q "issue reopen 50" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "AR4: grandparent OPEN → reopen only #100, exit 0"
else
    fail "AR4: expected reopen 100 only (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
unset GH_MOCK_PARENT_NUM_100
teardown_mock

# ---------------------------------------------------------------------------
# AR5: no parent → no reopen, exit 0
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_PARENT_ABSENT_200=1
run_with_timeout 30 bash "$TARGET" nirecom/agents 200 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && ! grep -q "issue reopen" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "AR5: no parent → no reopen, exit 0"
else
    fail "AR5: expected no reopen with absent parent (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# AR6: reopen #100 fails; chain continues, reopen #50 succeeds → exit 1, WARN
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_PARENT_NUM_200=100
export GH_MOCK_STATE_100=CLOSED
export GH_MOCK_REOPEN_FAIL_100=1
export GH_MOCK_PARENT_NUM_100=50
export GH_MOCK_STATE_50=CLOSED
export GH_MOCK_PARENT_ABSENT_50=1
STDERR_OUT="$TMP/ar6-stderr.txt"
run_with_timeout 30 bash "$TARGET" nirecom/agents 200 >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 1 ] \
   && grep -q "issue reopen 100" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q "issue reopen 50" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && [ -s "$STDERR_OUT" ]; then
    pass "AR6: reopen failure aggregated → exit 1, both attempted, WARN to stderr"
else
    fail "AR6: expected exit 1 with both reopens attempted and WARN (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null) log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
unset GH_MOCK_PARENT_NUM_100 GH_MOCK_PARENT_ABSENT_50
teardown_mock

# ---------------------------------------------------------------------------
# AR7: <N> non-numeric → exit 1, stderr mentions validation
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/ar7-stderr.txt"
run_with_timeout 30 bash "$TARGET" nirecom/agents abc >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 1 ] && grep -qiE "validation|invalid|usage" "$STDERR_OUT" 2>/dev/null; then
    pass "AR7: non-numeric <N> → exit 1, stderr mentions validation"
else
    fail "AR7: expected exit 1 + validation stderr (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# AR8: <owner/repo> invalid → exit 1, stderr mentions validation
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/ar8-stderr.txt"
run_with_timeout 30 bash "$TARGET" "invalid@repo" 200 >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 1 ] && grep -qiE "validation|invalid|usage" "$STDERR_OUT" 2>/dev/null; then
    pass "AR8: invalid <owner/repo> → exit 1, stderr mentions validation"
else
    fail "AR8: expected exit 1 + validation stderr (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# AR9: 51-level chain → WARN "depth limit" on stderr, fail-open (exit 0)
# ---------------------------------------------------------------------------
setup_mock
# Build chain #1000 -> 999 -> ... -> 950 (51 levels), all CLOSED.
for i in $(seq 949 999); do
    export "GH_MOCK_PARENT_NUM_$((i + 1))=$i"
    export "GH_MOCK_STATE_$i=CLOSED"
done
export GH_MOCK_PARENT_NUM_950=949
# GH_MOCK_STATE_949 intentionally unset — depth limit must fire before reaching it.
STDERR_OUT="$TMP/ar9-stderr.txt"
run_with_timeout 30 bash "$TARGET" nirecom/agents 1000 >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] && grep -qi "depth limit" "$STDERR_OUT" 2>/dev/null; then
    pass "AR9: depth limit → WARN on stderr, fail-open exit 0"
else
    fail "AR9: expected fail-open exit 0 with depth-limit WARN (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
