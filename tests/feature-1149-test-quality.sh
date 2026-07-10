#!/usr/bin/env bash
# Tests: bin/check-table-driven.sh, bin/mutation-probe.sh, bin/check-false-green.sh
# Tags: test-quality, t1-d, t1-e1, t1-f, scope:issue-specific
#
# Integration tests for the test-quality bin/ scripts added in issue #1149.
# All cases are RED until /write-code creates the scripts.
#
# L3 gap:
# - Whether check-table-driven.sh correctly integrates with git --staged mode
# - Whether mutation-probe.sh works against real hooks/lib/bash-write-patterns.js
# - Whether check-false-green.sh handles multi-line assert_eq patterns correctly

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUT_CTD="$AGENTS_DIR/bin/check-table-driven.sh"
SUT_CFG="$AGENTS_DIR/bin/check-false-green.sh"
SUT_MP="$AGENTS_DIR/bin/mutation-probe.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

require_sut() {
    local label="$1" path="$2"
    if [ -x "$path" ] || [ -f "$path" ]; then return 0; fi
    fail "$label: $(basename "$path") not found (RED until /write-code)"
    return 1
}

echo "=== feature-1149 test-quality bin/ scripts ==="
echo ""

# --- CTD-1: check-table-driven.sh violation ---
# File with parser Tests header but no while IFS='|' read -r → expect exit 1
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
#!/usr/bin/env bash
# Tests: hooks/lib/command-parser.js
# Tags: some-tag
echo "no table-driven pattern here"
EOF
if require_sut "CTD-1" "$SUT_CTD"; then
    RC=0
    run_with_timeout 10 bash "$SUT_CTD" "$TMP" >/dev/null 2>&1 || RC=$?
    if [ "$RC" -eq 1 ]; then
        pass "CTD-1: violation detected (no table-driven pattern) → exit 1"
    else
        fail "CTD-1: expected exit 1, got exit $RC"
    fi
fi
rm -f "$TMP"

# --- CTD-2: check-table-driven.sh compliant ---
# File with parser Tests header AND while IFS='|' read -r → expect exit 0
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
#!/usr/bin/env bash
# Tests: hooks/lib/command-parser.sh
# Tags: some-tag
while IFS='|' read -r name input want; do
    echo "$name $input $want"
done <<'TABLE'
case1 | input1 | want1
TABLE
EOF
if require_sut "CTD-2" "$SUT_CTD"; then
    RC=0
    run_with_timeout 10 bash "$SUT_CTD" "$TMP" >/dev/null 2>&1 || RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "CTD-2: compliant file (table-driven present) → exit 0"
    else
        fail "CTD-2: expected exit 0, got exit $RC"
    fi
fi
rm -f "$TMP"

# --- CTD-3: check-table-driven.sh non-parser file ---
# File with non-parser Tests header → expect exit 0 (not applicable)
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/audit-tests.sh
# Tags: some-tag
echo "ordinary test file"
EOF
if require_sut "CTD-3" "$SUT_CTD"; then
    RC=0
    run_with_timeout 10 bash "$SUT_CTD" "$TMP" >/dev/null 2>&1 || RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "CTD-3: non-parser target file → exit 0 (not applicable)"
    else
        fail "CTD-3: expected exit 0 for non-parser target, got exit $RC"
    fi
fi
rm -f "$TMP"

# --- CFG-1: check-false-green.sh detects same-literal ---
# File with assert_eq "name" "x" "x" → expect exit 1
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
#!/usr/bin/env bash
assert_eq "test-name" "x" "x"
EOF
if require_sut "CFG-1" "$SUT_CFG"; then
    RC=0
    run_with_timeout 10 bash "$SUT_CFG" "$TMP" >/dev/null 2>&1 || RC=$?
    if [ "$RC" -eq 1 ]; then
        pass "CFG-1: same-literal assert_eq detected → exit 1"
    else
        fail "CFG-1: expected exit 1 for same-literal assert, got exit $RC"
    fi
fi
rm -f "$TMP"

# --- CFG-2: check-false-green.sh passes clean assertion ---
# File with assert_eq "name" "x" "$got" → expect exit 0
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
#!/usr/bin/env bash
got="something"
assert_eq "test-name" "x" "$got"
EOF
if require_sut "CFG-2" "$SUT_CFG"; then
    RC=0
    run_with_timeout 10 bash "$SUT_CFG" "$TMP" >/dev/null 2>&1 || RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "CFG-2: clean assertion (variable second arg) → exit 0"
    else
        fail "CFG-2: expected exit 0 for clean assertion, got exit $RC"
    fi
fi
rm -f "$TMP"

# --- MP-1: mutation-probe.sh --help exits 0 ---
if require_sut "MP-1" "$SUT_MP"; then
    RC=0
    run_with_timeout 10 bash "$SUT_MP" --help >/dev/null 2>&1 || RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "MP-1: mutation-probe.sh --help → exit 0"
    else
        fail "MP-1: expected exit 0 from --help, got exit $RC"
    fi
fi

# --- MP-2: mutation-probe.sh detects const regex in fixture (CONST_PATTERN uses -E) ---
# Regression guard: if -E flag is ever reverted to BRE, CONST_PATTERN yields 0 matches,
# the TOTAL==0 guard fires, the "no single-line const regex found" string appears, MP-2 fails.
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
const FOO_RE = /foo+/;
EOF
if require_sut "MP-2" "$SUT_MP"; then
    MP2_STDERR=""
    MP2_RC=0
    MP2_STDERR="$(run_with_timeout 30 bash "$SUT_MP" --test-cmd 'true' "$TMP" 2>&1 >/dev/null)" || MP2_RC=$?
    if echo "$MP2_STDERR" | grep -q "no single-line const regex found"; then
        fail "MP-2: CONST_PATTERN matched 0 regexes — -E flag regression (probe output: $MP2_STDERR)"
    else
        pass "MP-2: CONST_PATTERN detected const regex in fixture (no TOTAL==0 guard triggered)"
    fi
fi
rm -f "$TMP"

# --- MP-3: mutation-probe.sh emits TOTAL==0 guard when no const regex in fixture ---
# Complementary control for MP-2: when the fixture has NO single-line const regex,
# the probe must print "no single-line const regex found" to stderr and exit 1.
# Without this, a broken guard that never fires would leave MP-2 falsely green.
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
const x = 5;
function f() { return x; }
EOF
if require_sut "MP-3" "$SUT_MP"; then
    MP3_STDERR=""
    MP3_RC=0
    MP3_STDERR="$(run_with_timeout 30 bash "$SUT_MP" --test-cmd 'true' "$TMP" 2>&1 >/dev/null)" || MP3_RC=$?
    if [ "$MP3_RC" -eq 1 ] && echo "$MP3_STDERR" | grep -q "no single-line const regex found"; then
        pass "MP-3: TOTAL==0 guard fires correctly for fixture with no const regex (exit 1 + guard message)"
    else
        fail "MP-3: expected exit 1 + 'no single-line const regex found' in stderr; got exit $MP3_RC, stderr: $MP3_STDERR"
    fi
fi
rm -f "$TMP"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
