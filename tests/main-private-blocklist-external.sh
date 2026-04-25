#!/bin/bash
# Test suite for external blocklist loading from dotfiles-private
# Tests that scan-outbound.sh loads .private-info-blocklist from sibling dotfiles-private repo
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER="$DOTFILES_DIR/bin/scan-outbound.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

expect_detect() {
    local desc="$1" input="$2"
    if echo "$input" | "$SCANNER" --stdin test >/dev/null 2>&1; then
        fail "$desc — not detected"
    else
        pass "$desc"
    fi
}

expect_clean() {
    local desc="$1" input="$2"
    if echo "$input" | "$SCANNER" --stdin test >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — false positive"
    fi
}

# --- Setup: create temp directory structure simulating dotfiles + dotfiles-private ---
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_DOTFILES="$TMPBASE/dotfiles"
FAKE_PRIVATE="$TMPBASE/dotfiles-private"
mkdir -p "$FAKE_DOTFILES/bin"
mkdir -p "$FAKE_PRIVATE"

# Copy scanner to fake dotfiles
cp "$SCANNER" "$FAKE_DOTFILES/bin/scan-outbound.sh"
chmod +x "$FAKE_DOTFILES/bin/scan-outbound.sh"

# Use the fake scanner for tests
SCANNER="$FAKE_DOTFILES/bin/scan-outbound.sh"

# Create empty local allowlist (scanner expects it)
touch "$FAKE_DOTFILES/.private-info-allowlist"

echo "=== Normal Cases ==="

# Create external blocklist with test patterns
cat > "$FAKE_PRIVATE/.private-info-blocklist" << 'BLOCKLIST'
# Test pattern
(^|[^[:alnum:]_])testhost([^[:alnum:]_]|$)
BLOCKLIST

expect_detect "external blocklist pattern detected in stdin" \
    "deploy to testhost now"

# File mode test
TESTFILE="$TMPBASE/testinput.txt"
echo "config for testhost server" > "$TESTFILE"
if "$SCANNER" "$TESTFILE" >/dev/null 2>&1; then
    fail "external blocklist pattern detected in file mode — not detected"
else
    pass "external blocklist pattern detected in file mode"
fi

echo ""
echo "=== Error Cases ==="

# Remove external blocklist and verify scanner still works
rm "$FAKE_PRIVATE/.private-info-blocklist"

expect_clean "no external blocklist file — scanner works without error" \
    "some normal content"

# Remove entire dotfiles-private directory
rm -rf "$FAKE_PRIVATE"

expect_clean "no dotfiles-private directory — scanner works without error" \
    "some normal content"

echo ""
echo "=== Edge Cases ==="

# Recreate for edge case tests
mkdir -p "$FAKE_PRIVATE"

# Word boundary: should NOT match substrings
cat > "$FAKE_PRIVATE/.private-info-blocklist" << 'BLOCKLIST'
(^|[^[:alnum:]_])foxbox([^[:alnum:]_]|$)
(^|[^[:alnum:]_])catcat([^[:alnum:]_]|$)
BLOCKLIST

expect_detect "exact match: foxbox" "deploy to foxbox"
expect_detect "exact match: catcat" "config for catcat host"
expect_detect "foxbox at start of line" "foxbox is ready"
expect_detect "foxbox at end of line" "deploy to foxbox"
expect_detect "foxbox with punctuation" "fix foxbox, then test"

expect_clean "substring foxboxx does not match" "foxboxx is different"
expect_clean "substring afoxbox does not match" "afoxbox is different"
expect_clean "substring catcatx does not match" "catcatx is different"
expect_clean "substring xcatcat does not match" "xcatcat is different"

# Comments and blank lines
cat > "$FAKE_PRIVATE/.private-info-blocklist" << 'BLOCKLIST'
# This is a comment

(^|[^[:alnum:]_])realpattern([^[:alnum:]_]|$)

# Another comment
BLOCKLIST

expect_detect "pattern after comments/blanks detected" \
    "match realpattern here"
expect_clean "comment line content not treated as pattern" \
    "This is a comment"

# Windows CR/LF line endings
printf '(^|[^[:alnum:]_])crlftest([^[:alnum:]_]|$)\r\n' > "$FAKE_PRIVATE/.private-info-blocklist"

expect_detect "CRLF line endings handled correctly" \
    "match crlftest here"

# Empty blocklist file (0 bytes)
: > "$FAKE_PRIVATE/.private-info-blocklist"

expect_clean "empty blocklist file (0 bytes) — no error" \
    "some normal content"

# Single pattern blocklist
cat > "$FAKE_PRIVATE/.private-info-blocklist" << 'BLOCKLIST'
(^|[^[:alnum:]_])singletest([^[:alnum:]_]|$)
BLOCKLIST

expect_detect "single pattern blocklist works" \
    "match singletest here"

# Multiple violations on same line
cat > "$FAKE_PRIVATE/.private-info-blocklist" << 'BLOCKLIST'
(^|[^[:alnum:]_])alpha([^[:alnum:]_]|$)
(^|[^[:alnum:]_])beta([^[:alnum:]_]|$)
BLOCKLIST

output=$(echo "alpha and beta together" | "$SCANNER" --stdin test 2>&1) || true
alpha_count=$(echo "$output" | grep -c "alpha" || true)
beta_count=$(echo "$output" | grep -c "beta" || true)
if [ "$alpha_count" -ge 1 ] && [ "$beta_count" -ge 1 ]; then
    pass "multiple violations on same line — both detected"
else
    fail "multiple violations on same line — alpha=$alpha_count beta=$beta_count"
fi

echo ""
echo "=== Idempotency Cases ==="

cat > "$FAKE_PRIVATE/.private-info-blocklist" << 'BLOCKLIST'
(^|[^[:alnum:]_])idemptest([^[:alnum:]_]|$)
BLOCKLIST

result1=$(echo "check idemptest" | "$SCANNER" --stdin test 2>&1) || true
result2=$(echo "check idemptest" | "$SCANNER" --stdin test 2>&1) || true
if [ "$result1" = "$result2" ]; then
    pass "idempotent: same input produces same output"
else
    fail "idempotent: outputs differ"
fi

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi
