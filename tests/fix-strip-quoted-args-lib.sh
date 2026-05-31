#!/bin/bash
# tests/fix-strip-quoted-args-lib.sh
# Tests: hooks/lib/strip-quoted-args.js
# Tags: strip-quoted-args-lib
#
# Tests for hooks/lib/strip-quoted-args.js — exports stripQuotedArgs(str)
# which strips content inside double-quoted ("..."), single-quoted ('...'),
# and ANSI-C ($'...') quotes, leaving empty quote markers in place.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/strip-quoted-args.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

call_strip() {
    run_with_timeout 30 node -e "
      try {
        const { stripQuotedArgs } = require('$MODULE');
        console.log(JSON.stringify(stripQuotedArgs(process.argv[1])));
      } catch(e) { console.log('ERROR: '+e.message); }
    " -- "$1" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

test_no_quotes() {
    local r
    r="$(call_strip 'no quotes here')"
    if [ "$r" = '"no quotes here"' ]; then
        pass "no quotes — unchanged"
    else
        fail "no quotes: expected '\"no quotes here\"', got '$r'"
    fi
}

test_double_quoted_stripped() {
    local r
    r="$(call_strip 'git commit -m "branch -d"')"
    case "$r" in
        *'branch -d'*)
            fail "double-quoted: 'branch -d' still present in stripped result: $r"
            ;;
        *'git commit'*)
            pass "double-quoted content stripped (branch -d removed)"
            ;;
        *)
            fail "double-quoted: unexpected result: $r"
            ;;
    esac
}

test_single_quoted_stripped() {
    local r
    r="$(call_strip "echo 'branch -d'")"
    case "$r" in
        *"''\"")
            pass "single-quoted content stripped (ends with empty single quotes)"
            ;;
        *)
            fail "single-quoted: expected result to end with \"''\", got '$r'"
            ;;
    esac
}

test_ansi_c_quoted_stripped() {
    local r
    r="$(call_strip "echo \$'branch -d'")"
    case "$r" in
        *'branch -d'*)
            fail "ANSI-C quoted: 'branch -d' still present in stripped result: $r"
            ;;
        *echo*)
            pass "ANSI-C quoted content stripped (branch -d removed)"
            ;;
        *)
            fail "ANSI-C quoted: unexpected result: $r"
            ;;
    esac
}

test_fp_commit_message() {
    local r
    r="$(call_strip 'git commit -m "branch -d fix/foo"')"
    case "$r" in
        *"-d fix"*)
            fail "FP: stripped result must NOT contain '-d fix', got '$r'"
            ;;
        *)
            pass "no false positive: '-d fix' not in stripped result"
            ;;
    esac
}

test_empty_string() {
    local r
    r="$(call_strip '')"
    if [ "$r" = '""' ]; then
        pass "empty string -> empty JSON string"
    else
        fail "empty: expected '\"\"', got '$r'"
    fi
}

test_null_no_throw() {
    local r
    r="$(run_with_timeout 30 node -e "
      try {
        const { stripQuotedArgs } = require('$MODULE');
        const out = stripQuotedArgs(null);
        console.log(JSON.stringify({ok: true, falsy: !out, val: out === null ? 'null' : (out === undefined ? 'undefined' : String(out))}));
      } catch(e) { console.log('ERROR: '+e.message); }
    " 2>/dev/null)"
    case "$r" in
        *'"ok":true'*'"falsy":true'*)
            pass "stripQuotedArgs(null) does not throw, result is falsy"
            ;;
        *)
            fail "null handling: $r"
            ;;
    esac
}

test_escaped_quote_in_double() {
    local r
    r="$(call_strip 'echo "say \"hi\""')"
    if [ "$r" = '"echo \"\""' ]; then
        pass "escaped quote in double-quoted: 'echo \"\"'"
    else
        fail "escaped quote: expected '\"echo \\\"\\\"\"', got '$r'"
    fi
}

test_idempotency() {
    local a b
    a="$(call_strip 'git commit -m "branch -d"')"
    b="$(call_strip 'git commit -m "branch -d"')"
    if [ "$a" = "$b" ]; then
        pass "idempotent: two strips of same input match"
    else
        fail "not idempotent: a=$a b=$b"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

test_no_quotes
test_double_quoted_stripped
test_single_quoted_stripped
test_ansi_c_quoted_stripped
test_fp_commit_message
test_empty_string
test_null_no_throw
test_escaped_quote_in_double
test_idempotency

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
