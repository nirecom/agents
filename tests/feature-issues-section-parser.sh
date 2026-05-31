#!/bin/bash
# Tests: bin/parse-closes-issues, hooks/lib/parse-closes-issues.js
# Tags: parse, closes-issues, hook, bin, tests
# Tests for hooks/lib/parse-closes-issues.js — Issue #548 ## Issues section support.
#
# Tests the parser via the CLI wrapper `bin/parse-closes-issues` which prints
# a JSON array of numeric issue IDs.
#
# Some tests are RED (new ## Issues behavior not yet implemented); others pass
# on the current legacy ## closes_issues parser.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER_CLI="$AGENTS_DIR/bin/parse-closes-issues"

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

# Parser invocation returns a JSON array on stdout.
# Helper: write a fixture, run parser, capture JSON.
TMP=""

setup_tmp() {
    TMP="$(mktemp -d)"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
}

# Convert a JSON array like "[123,456]" to a space-separated list "123 456".
json_to_list() {
    # Strip brackets and replace commas with spaces.
    printf '%s' "$1" | tr -d '[]' | tr ',' ' ' | tr -s ' '
}

# Compare actual JSON output to expected space-separated id list.
# Usage: assert_ids "$OUT" "123 456"
assert_ids() {
    local actual_json="$1" expected="$2"
    local actual_list
    actual_list=$(json_to_list "$actual_json" | sed 's/^ *//;s/ *$//')
    local expected_list
    expected_list=$(printf '%s' "$expected" | sed 's/^ *//;s/ *$//')
    if [ "$actual_list" = "$expected_list" ]; then
        return 0
    fi
    return 1
}

# ===========================================================================
# Test 1: Legacy only — ## closes_issues with 123, 456 (no ## Issues) → 123 456
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## closes_issues
- 123
- 456
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" "123 456"; then
    pass "T1: legacy ## closes_issues only → 123 456"
else
    fail "T1: rc=$RC out='$OUT' expected [123,456]"
fi
teardown_tmp

# ===========================================================================
# Test 2: New ## Issues with `- #N` form → 123 456
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- #123
- #456
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" "123 456"; then
    pass "T2: new ## Issues with - #N → 123 456"
else
    fail "T2: rc=$RC out='$OUT' expected [123,456]"
fi
teardown_tmp

# ===========================================================================
# Test 3: New ## Issues with `- #N: title` form → 123 456
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- #123: My title
- #456: Other thing
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" "123 456"; then
    pass "T3: new ## Issues with - #N: title → 123 456"
else
    fail "T3: rc=$RC out='$OUT' expected [123,456]"
fi
teardown_tmp

# ===========================================================================
# Test 4: New ## Issues with `- N` (no #) form → 123 456
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- 123
- 456
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" "123 456"; then
    pass "T4: new ## Issues with - N → 123 456"
else
    fail "T4: rc=$RC out='$OUT' expected [123,456]"
fi
teardown_tmp

# ===========================================================================
# Test 5: ## Issues empty + stale ## closes_issues → EMPTY (regression).
# Once ## Issues is recognized, an empty body in that section MUST win.
# The stale legacy ## closes_issues must NOT be used as fallback.
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues

## closes_issues
- 789
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" ""; then
    pass "T5: ## Issues empty + stale ## closes_issues → empty (regression)"
else
    fail "T5: rc=$RC out='$OUT' expected []"
fi
teardown_tmp

# ===========================================================================
# Test 6: ## Issues stops at next ## heading → only 111
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- #111

## Other
- #222
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" "111"; then
    pass "T6: ## Issues terminates at next ## heading → 111"
else
    fail "T6: rc=$RC out='$OUT' expected [111]"
fi
teardown_tmp

# ===========================================================================
# Test 7: Both absent — no ## Issues, no ## closes_issues → empty
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

Just some prose without either section heading.
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" ""; then
    pass "T7: neither section present → empty"
else
    fail "T7: rc=$RC out='$OUT' expected []"
fi
teardown_tmp

# ===========================================================================
# Test 8: Legacy fallback — no ## Issues but ## closes_issues present → legacy numbers
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## closes_issues
- 555
- 666
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" "555 666"; then
    pass "T8: legacy fallback when ## Issues absent → 555 666"
else
    fail "T8: rc=$RC out='$OUT' expected [555,666]"
fi
teardown_tmp

# ===========================================================================
# Test 9: ## Issues wins over ## closes_issues when both present and populated
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- #111

## closes_issues
- 999
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" "111"; then
    pass "T9: ## Issues wins over ## closes_issues → 111 only"
else
    fail "T9: rc=$RC out='$OUT' expected [111]"
fi
teardown_tmp

# ===========================================================================
# Test 10: CRLF line endings — same as T1 but with \r\n → parses correctly
# ===========================================================================
setup_tmp
# Use printf to produce literal CRLF line endings.
printf '# Intent\r\n\r\n## closes_issues\r\n- 123\r\n- 456\r\n' > "$TMP/intent.md"
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && assert_ids "$OUT" "123 456"; then
    pass "T10: CRLF line endings → 123 456"
else
    fail "T10: rc=$RC out='$OUT' expected [123,456]"
fi
teardown_tmp

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
