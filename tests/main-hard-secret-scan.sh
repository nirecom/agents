#!/bin/bash
# Test suite for hard-secret pattern detection in scan-outbound.sh
# Tests that the scanner detects API keys, tokens, and private keys with
# distinct labels in the output.
#
# NOTE: Most Normal cases will FAIL until the scanner is extended with the
# corresponding patterns. Edge/Empty/Allowlist cases should pass earlier.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER_SRC="$DOTFILES_DIR/bin/scan-outbound.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (macOS lacks `timeout`)
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 "$@"
    else
        perl -e 'alarm 60; exec @ARGV' -- "$@"
    fi
}

# --- Setup: fake dotfiles tree so tests don't depend on the real allowlist ---
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_DOTFILES="$TMPBASE/dotfiles"
FAKE_PRIVATE="$TMPBASE/dotfiles-private"
mkdir -p "$FAKE_DOTFILES/bin"
mkdir -p "$FAKE_PRIVATE"

cp "$SCANNER_SRC" "$FAKE_DOTFILES/bin/scan-outbound.sh"
chmod +x "$FAKE_DOTFILES/bin/scan-outbound.sh"

SCANNER="$FAKE_DOTFILES/bin/scan-outbound.sh"

# Empty local allowlist (scanner expects it)
: > "$FAKE_DOTFILES/.private-info-allowlist"

# Helper: scanner output for a given input. Always succeeds (captures stderr+stdout).
scan_output() {
    local input="$1"
    local label="${2:-test.txt}"
    # Use a subshell so set -e in the caller doesn't trip on non-zero exit
    printf '%s\n' "$input" | run_with_timeout "$SCANNER" --stdin "$label" 2>&1 || true
}

# Helper: assert scanner output contains the expected label string
expect_label() {
    local desc="$1" input="$2" label="$3"
    local out
    out="$(scan_output "$input")"
    if echo "$out" | grep -qF "$label"; then
        pass "$desc"
    else
        fail "$desc — expected label '$label' in output. Got: $(echo "$out" | tr '\n' '|')"
    fi
}

# Helper: assert scanner produced no violations (exit 0, no '[...]' label)
expect_clean() {
    local desc="$1" input="$2"
    if printf '%s\n' "$input" | run_with_timeout "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — false positive on input: $input"
    fi
}

# Helper: assert scanner detected SOMETHING (exit non-zero)
expect_detect_any() {
    local desc="$1" input="$2"
    if printf '%s\n' "$input" | run_with_timeout "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
        fail "$desc — not detected"
    else
        pass "$desc"
    fi
}

echo "=== Normal Cases (detection + label) ==="

expect_label "AWS Access Key labeled [aws-key]" \
    "AKIAIOSFODNN7EXAMPLE" "[aws-key]"

expect_label "PEM private key header labeled [private-key]" \
    "-----BEGIN RSA PRIVATE KEY-----" "[private-key]"

expect_label "GitHub PAT labeled [github-token]" \
    "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789" "[github-token]"

expect_label "Slack token labeled [slack-token]" \
    "xoxb-1234-5678-EXAMPLEfaketoken" "[slack-token]"

expect_label "OpenAI key labeled [openai-key]" \
    "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL" "[openai-key]"

expect_label "Anthropic key labeled [anthropic-key]" \
    "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789" "[anthropic-key]"

expect_label "Google API key labeled [google-key]" \
    "AIzaSyAbcdefghijklmnopqrstuvwxyz0123456789ab" "[google-key]"

expect_label "HuggingFace token labeled [huggingface-token]" \
    "hf_abcdefghijklmnopqrstuvwxyz0123456789AB" "[huggingface-token]"

expect_label "Groq key labeled [groq-key]" \
    "gsk_abcdefghijklmnopqrstuvwxyz0123456789abcdefghijkl" "[groq-key]"

expect_label "Replicate token labeled [replicate-token]" \
    "r8_abcdefghijklmnopqrstuvwxyz0123456789A" "[replicate-token]"

expect_label "Cohere key labeled [cohere-key]" \
    "co_abcdefghijklmnopqrstuvwxyz0123456789abcd" "[cohere-key]"

echo ""
echo "=== Error Cases (no false positive on short/invalid) ==="

expect_clean "AKIA alone (too short) — not detected" \
    "AKIA"

expect_clean "sk-test (too short) — not detected" \
    "sk-test"

expect_clean "sk-proj alone — not detected" \
    "sk-proj"

echo ""
echo "=== Edge Cases ==="

# Empty input — exit 0, no violations
if printf '' | run_with_timeout "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
    pass "empty input — exit 0, no violations"
else
    fail "empty input — scanner exited non-zero"
fi

expect_label "AWS key inside URL query string still detected" \
    "https://example.com/?key=AKIAIOSFODNN7EXAMPLE" "[aws-key]"

echo ""
echo "=== Idempotency Cases ==="

input1="AKIAIOSFODNN7EXAMPLE and ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
result1="$(scan_output "$input1")"
result2="$(scan_output "$input1")"
if [ "$result1" = "$result2" ]; then
    pass "idempotent: scanning same content twice produces identical output"
else
    fail "idempotent: outputs differ"
fi

echo ""
echo "=== Security Cases (allowlist) ==="

# Add the Anthropic dummy to the allowlist; it should be suppressed
cat > "$FAKE_DOTFILES/.private-info-allowlist" << 'EOF'
sk-ant-api03-dummyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
EOF

expect_clean "allowlisted Anthropic key suppressed" \
    "sk-ant-api03-dummyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

# Other secrets still detected when only one is allowlisted
expect_label "non-allowlisted AWS key still detected when one secret is allowlisted" \
    "AKIAIOSFODNN7EXAMPLE" "[aws-key]"

# Reset allowlist for cleanliness
: > "$FAKE_DOTFILES/.private-info-allowlist"

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi
