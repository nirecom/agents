#!/bin/bash
# Test suite for external allowlist loading from dotfiles-private
# Tests that scan-outbound.sh loads .private-info-allowlist from sibling dotfiles-private repo
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER="$DOTFILES_DIR/bin/scan-outbound.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

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

# Helper: expect violation detected (scanner exits non-zero)
expect_detect() {
    local desc="$1" input="$2" label="${3:-test}"
    if echo "$input" | "$SCANNER" --stdin "$label" >/dev/null 2>&1; then
        fail "$desc — not detected"
    else
        pass "$desc"
    fi
}

# Helper: expect no violation (scanner exits zero)
expect_clean() {
    local desc="$1" input="$2" label="${3:-test}"
    if echo "$input" | "$SCANNER" --stdin "$label" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — false positive"
    fi
}

echo "=== Normal Cases ==="

# 1. Global pattern in external allowlist suppresses IP detection
cat > "$FAKE_PRIVATE/.private-info-allowlist" << 'EOF'
10.99.99.99
EOF

expect_clean "global pattern in external allowlist suppresses IP detection" \
    "version 10.99.99.99 installed"

# 2. File-scoped pattern suppresses for matching file
cat > "$FAKE_PRIVATE/.private-info-allowlist" << 'EOF'
myfile.txt:192.168
EOF

expect_clean "file-scoped pattern suppresses for matching file" \
    "connect to 192.168.1.100" "myfile.txt"

# 3. File-scoped pattern does NOT suppress for non-matching file
expect_detect "file-scoped pattern does NOT suppress for non-matching file" \
    "connect to 192.168.1.100" "other.txt"

# 4. Both local and external allowlists work simultaneously
cat > "$FAKE_DOTFILES/.private-info-allowlist" << 'EOF'
10.88.88.88
EOF
cat > "$FAKE_PRIVATE/.private-info-allowlist" << 'EOF'
10.77.77.77
EOF

expect_clean "local allowlist suppresses its pattern" \
    "version 10.88.88.88 installed"
expect_clean "external allowlist suppresses its pattern" \
    "version 10.77.77.77 installed"

# Reset local allowlist to empty for remaining tests
: > "$FAKE_DOTFILES/.private-info-allowlist"

echo ""
echo "=== Error Cases ==="

# 5. No external allowlist file — scanner works
rm -f "$FAKE_PRIVATE/.private-info-allowlist"

expect_clean "no external allowlist file — scanner works without error" \
    "some normal content"

# 6. No dotfiles-private directory — scanner works
rm -rf "$FAKE_PRIVATE"

expect_clean "no dotfiles-private directory — scanner works without error" \
    "some normal content"

echo ""
echo "=== Edge Cases ==="

# Recreate for edge case tests
mkdir -p "$FAKE_PRIVATE"

# 7. Empty external allowlist (0 bytes) — no error, detection still works
: > "$FAKE_PRIVATE/.private-info-allowlist"

expect_detect "empty external allowlist — IP still detected" \
    "version 10.50.50.50 installed"

# 8. CRLF line endings handled correctly
printf '10.55.55.55\r\n' > "$FAKE_PRIVATE/.private-info-allowlist"

expect_clean "CRLF line endings handled correctly" \
    "version 10.55.55.55 installed"

# 9. Comments and blank lines skipped
cat > "$FAKE_PRIVATE/.private-info-allowlist" << 'EOF'
# This is a comment about 10.60.60.60

10.66.66.66
# Another comment
EOF

expect_clean "pattern after comments/blanks is loaded" \
    "version 10.66.66.66 installed"
expect_detect "comment content not treated as allowlist pattern" \
    "version 10.60.60.60 installed"

# 10. Glob file-scoped pattern matches
cat > "$FAKE_PRIVATE/.private-info-allowlist" << 'EOF'
tests/*:192.168
EOF

expect_clean "glob file-scoped pattern matches" \
    "connect to 192.168.1.1" "tests/foo.sh"

# 11. Glob file-scoped pattern does NOT match wrong directory
expect_detect "glob file-scoped pattern does NOT match wrong directory" \
    "connect to 192.168.1.1" "src/foo.sh"

echo ""
echo "=== Idempotency Cases ==="

# 12. Same input produces same output across repeated runs
cat > "$FAKE_PRIVATE/.private-info-allowlist" << 'EOF'
10.42.42.42
EOF

result1=$(echo "version 10.42.42.42 installed" | "$SCANNER" --stdin test 2>&1) || true
result2=$(echo "version 10.42.42.42 installed" | "$SCANNER" --stdin test 2>&1) || true
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
