#!/bin/bash
# tests/bin-sweep-band-loop.sh
# Tests: bin/lib/sweep-band-loop.sh
# Tags: sweep, band-loop, scope:common, TL1
#
# Unit tests for sweep_band_indices <total_count> <band_size>: emits one 0-based
# band index per line (0..ceil(total/size)-1), no output on total 0, non-zero
# exit + stderr on an invalid band_size. Pre-implementation the library is
# absent, so every case fails with a clear "library not found" message.

set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/lib/sweep-band-loop.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Invoke the function in a timed subshell that sources the library fresh. A
# missing library makes `source` fail (exit 127) so the caller sees a non-zero
# rc and empty stdout — never a hang, never a false green.
band_indices() {
    run_with_timeout bash -c 'source "$1" >/dev/null 2>&1 || exit 127; sweep_band_indices "$2" "$3"' \
        _ "$LIB" "$1" "$2"
}

# ── Value cases: assert exact stdout AND exit 0 ──────────────────────────────
check_lines() {
    local name="$1" total="$2" size="$3" want="$4"
    if [ ! -f "$LIB" ]; then
        fail "$name: library not found at $LIB (sweep-band-loop.sh is not implemented yet)"
        return
    fi
    local got rc
    got="$(band_indices "$total" "$size" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name: exit=$rc (want 0) for total=$total size=$size; out='$got'"
        return
    fi
    if [ "$got" = "$want" ]; then
        pass "$name: total=$total size=$size -> $(echo "$want" | tr '\n' ' ')"
    else
        fail "$name: total=$total size=$size got '$(echo "$got" | tr '\n' ',')' want '$(echo "$want" | tr '\n' ',')'"
    fi
}

# ── Empty case: no output, exit 0 ────────────────────────────────────────────
check_empty() {
    local name="$1" total="$2" size="$3"
    if [ ! -f "$LIB" ]; then
        fail "$name: library not found at $LIB (sweep-band-loop.sh is not implemented yet)"
        return
    fi
    local got rc
    got="$(band_indices "$total" "$size" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$got" ]; then
        pass "$name: total=$total size=$size -> no output, exit 0"
    else
        fail "$name: total=$total size=$size expected empty+exit0, got rc=$rc out='$got'"
    fi
}

# ── Error cases: non-zero exit, message on stderr, no indices on stdout ───────
check_error() {
    local name="$1" total="$2" size="$3"
    if [ ! -f "$LIB" ]; then
        fail "$name: library not found at $LIB (sweep-band-loop.sh is not implemented yet)"
        return
    fi
    local out err rc
    out="$(band_indices "$total" "$size" 2>/dev/null)"; rc=$?
    err="$(band_indices "$total" "$size" 2>&1 >/dev/null)"
    if [ "$rc" -eq 0 ]; then
        fail "$name: exit 0 for invalid size='$size' (want non-zero); out='$out'"
        return
    fi
    if [ -n "$err" ]; then
        pass "$name: invalid size='$size' -> non-zero exit ($rc) with stderr message"
    else
        fail "$name: invalid size='$size' exited $rc but wrote nothing to stderr"
    fi
}

# A1: 493/100 -> ceil = 5 bands (0 1 2 3 4)
check_lines "A1 non-divisible"   493 100 "$(printf '0\n1\n2\n3\n4')"
# A2: 200/100 -> exactly 2 bands (0 1)
check_lines "A2 divisible"       200 100 "$(printf '0\n1')"
# A3: total 0 -> no bands
check_empty "A3 zero total"        0 100
# A4: total < size -> single band 0
check_lines "A4 total<size"       30 100 "0"
# A5: total == size -> single band 0
check_lines "A5 total==size"     100 100 "0"
# A6: band_size 0 -> invalid
check_error "A6 zero size"       100 0
# A7: band_size non-numeric -> invalid
check_error "A7 non-numeric size" 100 "abc"
# A8: minimal 1/1 -> single band 0
check_lines "A8 one/one"           1 1 "0"

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
