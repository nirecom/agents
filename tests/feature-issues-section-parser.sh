#!/bin/bash
# Tests: bin/parse-closes-issues, hooks/lib/parse-closes-issues.js
# Tags: parse, closes-issues, hook, bin, tests, scope:common, cross-repo
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
# Usage: assert_nums "$OUT" "123 456"
assert_nums() {
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

# Extract issue numbers from JSON array (handles both Number[] and {number,...}[] formats).
# Usage: assert_nums "$OUT" "123 456"
assert_nums() {
    local actual_json="$1" expected="$2"
    local actual_nums
    actual_nums=$(node -e "
      try {
        const a = JSON.parse(process.argv[1]);
        if (!Array.isArray(a)) { process.stdout.write(''); process.exit(0); }
        process.stdout.write(a.map(e => typeof e === 'number' ? String(e) : String(e.number)).join(' '));
      } catch(e) { process.stdout.write(''); }
    " "$actual_json" 2>/dev/null)
    local expected_list actual_list
    expected_list=$(printf '%s' "$expected" | sed 's/^ *//;s/ *$//')
    actual_list=$(printf '%s' "$actual_nums" | sed 's/^ *//;s/ *$//')
    [ "$actual_list" = "$expected_list" ]
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" "123 456"; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" "123 456"; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" "123 456"; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" "123 456"; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" ""; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" "111"; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" ""; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" "555 666"; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" "111"; then
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
if [ "$RC" -eq 0 ] && assert_nums "$OUT" "123 456"; then
    pass "T10: CRLF line endings → 123 456"
else
    fail "T10: rc=$RC out='$OUT' expected [123,456]"
fi
teardown_tmp

# ===========================================================================
# Cross-repo wire format tests (RED until parse-closes-issues.js updated)
# Issue #1100/#1101: parser must return {number,repo?} objects, not plain nums
# ===========================================================================

# Helper: extract a field from a JSON object in the array.
# Usage: json_field_at_index "$JSON" <index> <field>
# Returns the raw value (string without quotes, or number).
json_field_at_index() {
    local json="$1" idx="$2" field="$3"
    node -e "
      try {
        const arr = JSON.parse(process.argv[1]);
        const obj = arr[parseInt(process.argv[2])];
        if (obj === undefined) { process.exit(1); }
        const v = obj[process.argv[3]];
        if (v === undefined) { process.stdout.write(''); }
        else { process.stdout.write(String(v)); }
      } catch(e) { process.exit(1); }
    " "$json" "$idx" "$field" 2>/dev/null
}

# ===========================================================================
# Test 11: cross-repo short form `- repo#42` → {repo:"myrepo", number:42}
# RED: current source returns Number[], not objects.
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- myrepo#42
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
NUMBER_AT_0=$(json_field_at_index "$OUT" 0 number 2>/dev/null)
REPO_AT_0=$(json_field_at_index "$OUT" 0 repo 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$NUMBER_AT_0" = "42" ] && [ "$REPO_AT_0" = "myrepo" ]; then
    pass "T11: cross-repo short form 'repo#42' → {repo:\"myrepo\", number:42}"
else
    fail "T11: rc=$RC out='$OUT' number='$NUMBER_AT_0' repo='$REPO_AT_0' expected {repo:myrepo,number:42}"
fi
teardown_tmp

# ===========================================================================
# Test 12: cross-repo full form `- owner/repo#42` → {repo:"owner/repo", number:42}
# RED: current source returns Number[], not objects.
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- owner/myrepo#42
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
NUMBER_AT_0=$(json_field_at_index "$OUT" 0 number 2>/dev/null)
REPO_AT_0=$(json_field_at_index "$OUT" 0 repo 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$NUMBER_AT_0" = "42" ] && [ "$REPO_AT_0" = "owner/myrepo" ]; then
    pass "T12: cross-repo full form 'owner/repo#42' → {repo:\"owner/myrepo\", number:42}"
else
    fail "T12: rc=$RC out='$OUT' number='$NUMBER_AT_0' repo='$REPO_AT_0' expected {repo:owner/myrepo,number:42}"
fi
teardown_tmp

# ===========================================================================
# Test 13: cross-repo full form with title `- owner/repo#42: title with spaces`
# RED: current source returns Number[], not objects.
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- owner/myrepo#42: add cross-repo support
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
NUMBER_AT_0=$(json_field_at_index "$OUT" 0 number 2>/dev/null)
REPO_AT_0=$(json_field_at_index "$OUT" 0 repo 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$NUMBER_AT_0" = "42" ] && [ "$REPO_AT_0" = "owner/myrepo" ]; then
    pass "T13: cross-repo with title 'owner/repo#42: title' → {repo:\"owner/myrepo\", number:42}"
else
    fail "T13: rc=$RC out='$OUT' number='$NUMBER_AT_0' repo='$REPO_AT_0' expected {repo:owner/myrepo,number:42}"
fi
teardown_tmp

# ===========================================================================
# Test 14: mixed `- #1` + `- repo#2` + `- owner/repo#3` → 3-element array
# RED: current source returns Number[], not objects.
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- #1
- myrepo#2
- owner/myrepo#3
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(node -e "try{const a=JSON.parse(process.argv[1]);process.stdout.write(String(a.length));}catch(e){process.stdout.write('0');}" "$OUT" 2>/dev/null)
N0=$(json_field_at_index "$OUT" 0 number 2>/dev/null)
N1=$(json_field_at_index "$OUT" 1 number 2>/dev/null)
N2=$(json_field_at_index "$OUT" 2 number 2>/dev/null)
R1=$(json_field_at_index "$OUT" 1 repo 2>/dev/null)
R2=$(json_field_at_index "$OUT" 2 repo 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$LEN" = "3" ] && [ "$N0" = "1" ] && [ "$N1" = "2" ] && [ "$N2" = "3" ] && [ "$R1" = "myrepo" ] && [ "$R2" = "owner/myrepo" ]; then
    pass "T14: mixed formats → 3-element object array"
else
    fail "T14: rc=$RC out='$OUT' len=$LEN n=[$N0,$N1,$N2] repos=[$R1,$R2] expected 3-element array with repos"
fi
teardown_tmp

# ===========================================================================
# Test 15: CLI output is JSON object array (not number array) for cross-repo
# RED: current CLI returns numbers, not objects.
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- owner/myrepo#7
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
# Must NOT be a simple number array like [7]; must have 'number' key
IS_OBJECT_ARRAY=$(node -e "
  try {
    const a = JSON.parse(process.argv[1]);
    if (Array.isArray(a) && a.length > 0 && typeof a[0] === 'object' && 'number' in a[0]) {
      process.stdout.write('yes');
    } else {
      process.stdout.write('no');
    }
  } catch(e) { process.stdout.write('no'); }
" "$OUT" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$IS_OBJECT_ARRAY" = "yes" ]; then
    pass "T15: CLI returns object array (not number array) for cross-repo entries"
else
    fail "T15: rc=$RC out='$OUT' is_object_array='$IS_OBJECT_ARRAY' expected [{number:7,repo:\"owner/myrepo\"}]"
fi
teardown_tmp

# ===========================================================================
# Test 16: backward-compat — `- #5: title` → [{number:5}] (no repo field)
# RED: current source returns [5] (number), not [{number:5}] (object).
# When source is updated, this guards that same-repo issues stay object-shaped.
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- #5: backward compat title
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
NUMBER_AT_0=$(json_field_at_index "$OUT" 0 number 2>/dev/null)
REPO_AT_0=$(json_field_at_index "$OUT" 0 repo 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$NUMBER_AT_0" = "5" ] && [ -z "$REPO_AT_0" ]; then
    pass "T16: backward-compat '- #5: title' → [{number:5}] (no repo field)"
else
    fail "T16: rc=$RC out='$OUT' number='$NUMBER_AT_0' repo='$REPO_AT_0' expected [{number:5}] no repo"
fi
teardown_tmp

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
