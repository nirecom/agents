#!/bin/bash
# Tests for issue #449 — bin/github-issues/check-closes-issues-nonempty.sh
#
# Guard script that verifies the session's intent.md has a non-empty
# ## closes_issues section. Called by clarify-intent's Completion section
# to prevent the workflow from proceeding with an empty tracking list.
#
# Uses hooks/lib/parse-closes-issues.js as the SSOT parser (via node -e).
#
# RED: this suite fails clean while the guard script is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$AGENTS_DIR/bin/github-issues/check-closes-issues-nonempty.sh"

# So `node -e "require('hooks/lib/parse-closes-issues.js')"` resolves
# correctly from the guard script (which uses AGENTS_CONFIG_DIR).
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

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
if [ ! -f "$CHECK" ]; then
    echo "FAIL: precondition missing — bin/github-issues/check-closes-issues-nonempty.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

setup_tmp() {
    TMP="$(mktemp -d)"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
}

# ============================================================================
# D-series — check-closes-issues-nonempty.sh
# ============================================================================

# --- D1: single closes_issues entry → rc=0, stderr empty
setup_tmp
printf '## closes_issues\n- 449\n' > "$TMP/intent.md"
STDERR=$(run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$STDERR" ]; then
    pass "D1: single entry → rc=0, stderr empty"
else
    fail "D1: rc=$RC stderr=$STDERR"
fi
teardown_tmp

# --- D2: empty closes_issues section → rc=1, stderr mentions /issue-create
setup_tmp
printf '## closes_issues\n(empty)\n' > "$TMP/intent.md"
STDERR=$(run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$STDERR" | grep -q "Run /issue-create"; then
    pass "D2: empty section → rc=1, stderr mentions Run /issue-create"
else
    fail "D2: rc=$RC stderr=$STDERR"
fi
teardown_tmp

# --- D3: bare header at EOF → rc=1
setup_tmp
printf '## closes_issues\n' > "$TMP/intent.md"
run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "D3: bare header at EOF → rc=1"
else
    fail "D3: rc=$RC"
fi
teardown_tmp

# --- D4: no closes_issues section → rc=1
setup_tmp
printf '# Some Intent\n\n## Other Section\n- 999\n' > "$TMP/intent.md"
run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "D4: no closes_issues section → rc=1"
else
    fail "D4: rc=$RC"
fi
teardown_tmp

# --- D5: --non-github flag skips check even with empty section → rc=0
setup_tmp
printf '## closes_issues\n(empty)\n' > "$TMP/intent.md"
run_with_timeout 15 bash "$CHECK" --non-github "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "D5: --non-github → rc=0 (skip regardless of content)"
else
    fail "D5: rc=$RC"
fi
teardown_tmp

# --- D6: multiple closes_issues entries → rc=0
setup_tmp
printf '## closes_issues\n- 449\n- 450\n' > "$TMP/intent.md"
run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "D6: multiple entries → rc=0"
else
    fail "D6: rc=$RC"
fi
teardown_tmp

# --- D7: nonexistent path → rc=1, stderr mentions "intent.md not found"
setup_tmp
STDERR=$(run_with_timeout 15 bash "$CHECK" "$TMP/does-not-exist.md" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$STDERR" | grep -q "intent.md not found"; then
    pass "D7: nonexistent path → rc=1, stderr mentions intent.md not found"
else
    fail "D7: rc=$RC stderr=$STDERR"
fi
teardown_tmp

# --- D8: no arguments → rc=1, stderr mentions "Usage:"
STDERR=$(run_with_timeout 15 bash "$CHECK" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$STDERR" | grep -q "Usage:"; then
    pass "D8: no arguments → rc=1, stderr mentions Usage:"
else
    fail "D8: rc=$RC stderr=$STDERR"
fi

# --- D9: section-boundary integrity — `- 999` under ## Other not counted
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Agreed Requirements

## closes_issues
(empty)

## Other
- 999
EOF
run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "D9: section-boundary integrity (entries under ## Other ignored) → rc=1"
else
    fail "D9: rc=$RC (parser may be ignoring ## boundary)"
fi
teardown_tmp

# --- D10: shell-injection isolation
setup_tmp
INJECT_FILE="$TMP/D10_INJECT_$$"
# Construct a literal filename containing $(touch ...) — must not execute.
FNAME='intent_$(touch '"$INJECT_FILE"').md'
touch "$TMP/$FNAME"
run_with_timeout 15 bash "$CHECK" "$TMP/$FNAME" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$INJECT_FILE" ]; then
    pass "D10: shell-injection isolation (rc=$RC, inject file not created)"
else
    fail "D10: rc=$RC inject_exists=$([ -f "$INJECT_FILE" ] && echo yes || echo no)"
fi
rm -f "$INJECT_FILE" 2>/dev/null
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
