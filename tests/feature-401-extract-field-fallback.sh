#!/bin/bash
# tests/feature-401-extract-field-fallback.sh
#
# TDD tests for extract_field_with_fallback() — will be added to
# bin/github-issues/lib/extract-field.sh (#401).
# RED until the function is implemented.

set -u

PASS=0
FAIL=0

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACT_LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"

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

TMPFILES=()
cleanup() {
    for f in "${TMPFILES[@]:-}"; do [ -n "${f:-}" ] && rm -rf "$f"; done
}
trap cleanup EXIT

# Source library (file must exist for any test to pass)
if [ ! -f "$EXTRACT_LIB" ]; then
    fail "extract-field.sh not found at $EXTRACT_LIB"
    echo ""
    echo "Passed: $PASS / $((PASS + FAIL))"
    exit 1
fi

# shellcheck disable=SC1090
. "$EXTRACT_LIB"

if ! declare -f extract_field_with_fallback >/dev/null 2>&1; then
    fail "extract_field_with_fallback function not defined (expected during TDD RED phase)"
fi

# Helper: invoke fallback if defined; otherwise return empty so tests fail predictably
call_fallback() {
    if declare -f extract_field_with_fallback >/dev/null 2>&1; then
        extract_field_with_fallback "$@"
    else
        printf ''
    fi
}

# -----------------------------------------------------------------------------
# F1: English Background:/Changes: headers present → extracted normally
# -----------------------------------------------------------------------------
BODY="Background: Existing background text
Changes: Existing changes text"
export BODY
got_bg="$(call_fallback Background "fallback-title" "fallback-body")"
got_ch="$(call_fallback Changes "fallback-title" "fallback-body")"
if [ "$got_bg" = "Existing background text" ] && [ "$got_ch" = "Existing changes text" ]; then
    pass "F1: existing headers → extracted normally, no fallback used"
else
    fail "F1: expected 'Existing background text'/'Existing changes text', got '$got_bg'/'$got_ch'"
fi

# -----------------------------------------------------------------------------
# F2: No headers + plain body → Background = fallback_title
# -----------------------------------------------------------------------------
BODY="just some plain body text with no field markers"
export BODY
got="$(call_fallback Background "my-title" "my-body")"
if [ "$got" = "my-title" ]; then
    pass "F2: no headers → Background falls back to title"
else
    fail "F2: expected 'my-title', got '$got'"
fi

# -----------------------------------------------------------------------------
# F3: Body "## 背景\n本文テスト" → H2 line skipped, first non-blank → Changes
# -----------------------------------------------------------------------------
BODY=""
export BODY
fallback_body="$(printf '## 背景\n本文テスト\n')"
got="$(call_fallback Changes "title-x" "$fallback_body")"
if [ "$got" = "本文テスト" ]; then
    pass "F3: Markdown H2 skipped, first non-blank line returned for Changes"
else
    fail "F3: expected '本文テスト', got '$got'"
fi

# -----------------------------------------------------------------------------
# F4: Empty body → fallback_title for Background
# -----------------------------------------------------------------------------
BODY=""
export BODY
got="$(call_fallback Background "only-title" "")"
if [ "$got" = "only-title" ]; then
    pass "F4: empty body → Background = fallback_title"
else
    fail "F4: expected 'only-title', got '$got'"
fi

echo ""
echo "Passed: $PASS / $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
