#!/bin/bash
# tests/unit-issue-create-dispatch-stdout.sh
# Tests: bin/github-issues/issue-create-dispatch.sh.
# Tags: issue-create, github, issues, bin, shell
#
# Unit tests for the stdout-URL extraction pipeline used by callers of
# bin/github-issues/issue-create-dispatch.sh.
#
# The dispatch script writes the final issue URL as the last line of stdout.
# Callers extract the issue number with:
#
#     URL=$(echo "$OUTPUT" | tail -n 1 | tr -d '\r')
#     N=$(echo "$URL" | grep -oE '[0-9]+$')
#
# These tests verify the extraction pipeline as a pure shell computation by
# stubbing the inputs — the dispatch script itself is not invoked. The
# dispatch script already exists, so no SKIP gating is required.

set -u

PASS=0; FAIL=0; SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

extract_url() {
    # Mirrors the caller pipeline: last line, strip \r.
    printf '%s' "$1" | tail -n 1 | tr -d '\r'
}

extract_number() {
    # Mirrors the caller pipeline: trailing digit run. May exit non-zero when
    # no match — that is acceptable in the contract.
    printf '%s' "$1" | grep -oE '[0-9]+$' || true
}

# ---- N1: single-line URL → number extracted ----
test_N1_single_line_url() {
    local out="https://github.com/owner/repo/issues/7"
    local url; url="$(extract_url "$out")"
    local n;   n="$(extract_number "$url")"
    if [ "$url" = "https://github.com/owner/repo/issues/7" ] && [ "$n" = "7" ]; then
        pass "N1: single-line URL → number '7'"
    else
        fail "N1: url='$url' n='$n'"
    fi
}

# ---- C1: multi-line output → tail -n 1 picks URL ----
test_C1_multi_line_url_last() {
    local out
    out="$(printf '%s\n' \
        "Creating issue..." \
        "Adding to project..." \
        "https://github.com/owner/repo/issues/42")"
    local url; url="$(extract_url "$out")"
    local n;   n="$(extract_number "$url")"
    if [ "$url" = "https://github.com/owner/repo/issues/42" ] && [ "$n" = "42" ]; then
        pass "C1: multi-line output → URL on last line, number '42'"
    else
        fail "C1: url='$url' n='$n'"
    fi
}

# ---- C2: URL with CRLF → tr -d '\r' strips carriage return ----
test_C2_crlf_url() {
    # Build CRLF line via printf.
    local out
    out="$(printf 'https://github.com/owner/repo/issues/13\r\n')"
    local url; url="$(extract_url "$out")"
    local n;   n="$(extract_number "$url")"
    # If \r is not stripped, the trailing-digit regex will not match against
    # "13\r" because \r breaks the $ anchor. Validate both URL and number.
    if [ "$url" = "https://github.com/owner/repo/issues/13" ] && [ "$n" = "13" ]; then
        pass "C2: CRLF URL → '\r' stripped, number '13' extracted"
    else
        # Show byte counts to disambiguate failures.
        local urlbytes
        urlbytes="$(printf '%s' "$url" | wc -c | tr -d ' ')"
        fail "C2: url='$url' (bytes=$urlbytes) n='$n'"
    fi
}

# ---- C3: URL with number 42 ----
test_C3_url_number_42() {
    local out="https://github.com/owner/repo/issues/42"
    local n; n="$(extract_number "$out")"
    if [ "$n" = "42" ]; then
        pass "C3: URL → number '42'"
    else
        fail "C3: n='$n'"
    fi
}

# ---- C4: URL without trailing number → empty result acceptable ----
test_C4_url_no_trailing_number() {
    local out="https://github.com/owner/repo/issues/"
    local n; n="$(extract_number "$out")"
    # extract_number swallows grep's non-zero exit via `|| true`; result is
    # empty string. The contract is: empty (or non-zero raw exit) is
    # acceptable for malformed input.
    if [ -z "$n" ]; then
        pass "C4: URL with no trailing number → empty result"
    else
        fail "C4: expected empty, got n='$n'"
    fi
}

# ============ Run all ============

test_N1_single_line_url
test_C1_multi_line_url_last
test_C2_crlf_url
test_C3_url_number_42
test_C4_url_no_trailing_number

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
