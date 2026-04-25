#!/usr/bin/env bash
# Test suite for Trojan Source / hidden-char detection in scan-outbound.sh
# Zero-width chars (U+200B/C/D, U+FEFF) → [zero-width]
# Bidi override chars (U+202D/E, U+2066-2069) → [bidi-override]
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER_SRC="$DOTFILES_DIR/bin/scan-outbound.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 "$@"
    else
        perl -e 'alarm 60; exec @ARGV' -- "$@"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_DOTFILES="$TMPBASE/dotfiles"
FAKE_PRIVATE="$TMPBASE/dotfiles-private"
mkdir -p "$FAKE_DOTFILES/bin"
mkdir -p "$FAKE_PRIVATE"
cp "$SCANNER_SRC" "$FAKE_DOTFILES/bin/scan-outbound.sh"
chmod +x "$FAKE_DOTFILES/bin/scan-outbound.sh"
SCANNER="$FAKE_DOTFILES/bin/scan-outbound.sh"
: > "$FAKE_DOTFILES/.private-info-allowlist"

scan_output() {
    local input="$1"
    local label="${2:-test.txt}"
    printf '%s\n' "$input" | run_with_timeout "$SCANNER" --stdin "$label" 2>&1 || true
}
expect_label() {
    local desc="$1" input="$2" label="$3"
    local out; out="$(scan_output "$input")"
    if echo "$out" | grep -qF "$label"; then
        pass "$desc"
    else
        fail "$desc — expected '$label'. Got: $(echo "$out" | tr '\n' '|')"
    fi
}
expect_clean() {
    local desc="$1" input="$2"
    if printf '%s\n' "$input" | run_with_timeout "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — false positive on: $input"
    fi
}

echo "=== Normal Cases: zero-width chars ==="
expect_label "U+200B (ZWSP) → [zero-width]"        $'hello\xe2\x80\x8bworld'     "[zero-width]"
expect_label "U+200C (ZWNJ) → [zero-width]"        $'hello\xe2\x80\x8cworld'     "[zero-width]"
expect_label "U+200D (ZWJ)  → [zero-width]"        $'hello\xe2\x80\x8dworld'     "[zero-width]"
expect_label "U+FEFF (BOM)  → [zero-width]"        $'\xef\xbb\xbfhello'          "[zero-width]"

echo ""
echo "=== Normal Cases: bidi override chars ==="
expect_label "U+202D (LRO)  → [bidi-override]"     $'hello\xe2\x80\xadworld'     "[bidi-override]"
expect_label "U+202E (RLO)  → [bidi-override]"     $'hello\xe2\x80\xaeworld'     "[bidi-override]"
expect_label "U+2066 (LRI)  → [bidi-override]"     $'hello\xe2\x81\xa6world'     "[bidi-override]"
expect_label "U+2067 (RLI)  → [bidi-override]"     $'hello\xe2\x81\xa7world'     "[bidi-override]"
expect_label "U+2068 (FSI)  → [bidi-override]"     $'hello\xe2\x81\xa8world'     "[bidi-override]"
expect_label "U+2069 (PDI)  → [bidi-override]"     $'hello\xe2\x81\xa9world'     "[bidi-override]"

echo ""
echo "=== Error Cases (no false positive) ==="
expect_clean "ASCII only — clean"                   "hello world 123"
expect_clean "Japanese text — clean"                "日本語テスト"
expect_clean "Latin extended (é, ü) — clean"       $'caf\xc3\xa9 R\xc3\xbcckgabe'

echo ""
echo "=== Edge Cases ==="
if printf '' | run_with_timeout "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
    pass "empty input — exit 0"
else
    fail "empty input — unexpected non-zero exit"
fi
expect_label "hidden char buried in long line still detected" \
    $'lots of text before \xe2\x80\x8b and lots of text after' "[zero-width]"

echo ""
echo "=== Idempotency Cases ==="
input1=$'code\xe2\x80\xaemalicious'
r1="$(scan_output "$input1")"; r2="$(scan_output "$input1")"
if [ "$r1" = "$r2" ]; then
    pass "scanning same content twice produces identical output"
else
    fail "outputs differ between runs"
fi

echo ""
echo "=== Security Cases (allowlist) ==="
printf '%s\n' $'hello\xe2\x80\x8bworld' > "$FAKE_DOTFILES/.private-info-allowlist"
if printf '%s\n' $'hello\xe2\x80\x8bworld' | run_with_timeout "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
    pass "allowlisted zero-width line suppressed"
else
    fail "allowlisted zero-width line still detected"
fi
expect_label "non-allowlisted bidi still detected when zwsp is allowlisted" \
    $'hello\xe2\x80\xaeworld' "[bidi-override]"
: > "$FAKE_DOTFILES/.private-info-allowlist"

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi
