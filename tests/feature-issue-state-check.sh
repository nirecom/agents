#!/usr/bin/env bash
# Tests: bin/github-issues/issue-state-check.sh
# Tags: github, issues, workflow-init, session-dedup
# Tests for bin/github-issues/issue-state-check.sh — single-issue state probe.
#
# Interface contract:
#   Usage: issue-state-check.sh <N>
#   stdout: exactly `open`, `closed`, or `error`
#   exit 0 for open/closed; exit 1 for error; exit 2 for bad args
#   Does NOT require AGENTS_CONFIG_DIR
#
# RED: this suite fails clean while bin/github-issues/issue-state-check.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/issue-state-check.sh"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Existence gate — pre-implementation: SKIP all cases gracefully.
if [ ! -f "$TARGET" ]; then
    echo "SKIP: bin/github-issues/issue-state-check.sh not yet present (pre-implementation)"
    echo ""
    echo "Results: 0 passed, 0 failed, 7 skipped"
    exit 0
fi

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*)
    if [ "${GH_MOCK_FAIL:-}" = "1" ]; then
        echo "error: gh api failed" >&2
        exit 1
    fi
    printf '%s\n' "${GH_MOCK_STATE:-OPEN}"
    exit 0 ;;
  *)
    echo "MOCK GH: no match $ARGS" >&2
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
        export PATH="${PATH#"$TMP/mock-bin:"}"
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset GH_MOCK_ARGS_LOG GH_MOCK_STATE GH_MOCK_FAIL 2>/dev/null || true
}

# E1: open issue → stdout 'open', exit 0
setup_mock
export GH_MOCK_STATE="OPEN"
OUT=$(run_with_timeout 15 bash "$TARGET" 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "open" ]; then
    pass "E1: open issue → stdout 'open', exit 0"
else
    fail "E1: rc=$RC out='$OUT' (expected 'open' rc=0)"
fi
teardown_mock

# E2: closed issue → stdout 'closed', exit 0
setup_mock
export GH_MOCK_STATE="CLOSED"
OUT=$(run_with_timeout 15 bash "$TARGET" 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "closed" ]; then
    pass "E2: closed issue → stdout 'closed', exit 0"
else
    fail "E2: rc=$RC out='$OUT' (expected 'closed' rc=0)"
fi
teardown_mock

# E3: gh fails → stdout 'error', exit 1 (+ stderr warning)
setup_mock
export GH_MOCK_FAIL=1
STDERR_FILE="$TMP/e3-stderr.log"
OUT=$(run_with_timeout 15 bash "$TARGET" 42 2>"$STDERR_FILE")
RC=$?
HAS_STDERR=0
[ -s "$STDERR_FILE" ] && HAS_STDERR=1
if [ "$RC" -eq 1 ] && [ "$OUT" = "error" ] && [ "$HAS_STDERR" -eq 1 ]; then
    pass "E3: gh fails → stdout 'error', exit 1, stderr non-empty"
else
    fail "E3: rc=$RC out='$OUT' stderr_present=$HAS_STDERR"
fi
teardown_mock

# E4: no args → exit 2
setup_mock
run_with_timeout 15 bash "$TARGET" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "E4: no args → exit 2"
else
    fail "E4: expected exit 2, got rc=$RC"
fi
teardown_mock

# E5: non-numeric arg → exit 2
setup_mock
run_with_timeout 15 bash "$TARGET" "abc" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "E5: non-numeric arg → exit 2"
else
    fail "E5: expected exit 2, got rc=$RC"
fi
teardown_mock

# E6: gh absent/failing → stdout 'error', exit 1
TMP="$(mktemp -d)"
EMPTY_BIN="$TMP/empty-bin"
mkdir -p "$EMPTY_BIN"
SAVED_PATH="$PATH"
# Place a placeholder gh that always fails (exit 127) — simulates absence
# without needing to manipulate PATH (more reliable across Windows/MSYS).
cat > "$EMPTY_BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: command not found (mocked)" >&2
exit 127
STUB
chmod +x "$EMPTY_BIN/gh"
export PATH="$EMPTY_BIN:$PATH"
STDERR_FILE="$TMP/e6-stderr.log"
OUT=$(run_with_timeout 15 bash "$TARGET" 42 2>"$STDERR_FILE")
RC=$?
export PATH="$SAVED_PATH"
if [ "$RC" -eq 1 ] && [ "$OUT" = "error" ]; then
    pass "E6: gh absent/failing → stdout 'error', exit 1"
else
    fail "E6: rc=$RC out='$OUT' stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
rm -rf "$TMP" 2>/dev/null || true
TMP=""

# E7: AGENTS_CONFIG_DIR unset → still works
setup_mock
export GH_MOCK_STATE="OPEN"
SAVED_ACD="${AGENTS_CONFIG_DIR:-}"
unset AGENTS_CONFIG_DIR
OUT=$(run_with_timeout 15 bash "$TARGET" 42 2>/dev/null)
RC=$?
[ -n "$SAVED_ACD" ] && export AGENTS_CONFIG_DIR="$SAVED_ACD"
if [ "$RC" -eq 0 ] && [ "$OUT" = "open" ]; then
    pass "E7: AGENTS_CONFIG_DIR unset → still works (out='open', rc=0)"
else
    fail "E7: rc=$RC out='$OUT' (script must not require AGENTS_CONFIG_DIR)"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
exit $((FAIL > 0 ? 1 : 0))
