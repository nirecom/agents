#!/bin/bash
# tests/feature-1226-load-env-os-blocks.sh
# Tests: hooks/lib/load-env.js
# Tags: scope:issue-specific, load-env, env-os-blocks, os-conditional, pwsh-not-required
# RED for issue #1226 — filterOsBlocks(text, platform) OS-conditional preprocessor.
# L3 gap (what this test does NOT catch):
# - real cross-OS behavior of a SINGLE .env symlinked across Windows and macOS;
#   only exercising both real OSes proves the same file yields the right block
#   on each platform. T1226-12 covers only the running platform's process.platform.
# Capability guard: filterOsBlocks is not exported until write-code lands. When it
# is absent, every dependent case SKIPs and the suite stays green (0 FAIL).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

LOAD_ENV="$AGENTS_DIR/hooks/lib/load-env.js"
LOAD_ENV_NODE="$_AGENTS_DIR_NODE/hooks/lib/load-env.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Capability probe: is filterOsBlocks exported yet? Only gate between
# real-assertion and skip-pending-implementation. No stub, no fake.
HAS_FN=0
if [ -f "$LOAD_ENV" ]; then
    HAS_FN=$(run_with_timeout 5 node -e "
const m = require(process.argv[1]);
process.stdout.write(typeof m.filterOsBlocks === 'function' ? '1' : '0');
" "$LOAD_ENV_NODE" 2>/dev/null) || HAS_FN=0
fi
[ "$HAS_FN" = "1" ] || HAS_FN=0

# Invoke filterOsBlocks(text, platform) and emit its return value to stdout.
# platform passed directly as a param — NO process.platform mock.
filter_os_blocks() {
    local input="$1" platform="$2"
    run_with_timeout 5 node -e "
const m = require(process.argv[1]);
const out = m.filterOsBlocks(process.argv[2], process.argv[3]);
process.stdout.write(out);
" "$LOAD_ENV_NODE" "$input" "$platform" 2>/dev/null
}

# Assertion helpers — every message carries the case name. Each compares real
# function output against the expected substring (never a literal against itself).
assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$name (contains '$needle')"
    else
        fail "$name (expected to contain '$needle'; got: $(printf '%s' "$haystack" | tr '\n' '|'))"
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$name (expected NOT to contain '$needle'; got: $(printf '%s' "$haystack" | tr '\n' '|'))"
    else
        pass "$name (omits '$needle')"
    fi
}

# assert_empty — the captured output must be exactly the empty string. Compares
# real captured output against "" (no needle, so assert_contains can't express it).
assert_empty() {
    local name="$1" haystack="$2"
    if [ -z "$haystack" ]; then
        pass "$name (output is empty)"
    else
        fail "$name (expected empty output; got: $(printf '%s' "$haystack" | tr '\n' '|'))"
    fi
}

# ---------------------------------------------------------------------------
# Table-driven cases T1226-1 .. T1226-10. Each row: name | input | platform |
# then one or more contains/not-contains assertions applied to the output.
# ---------------------------------------------------------------------------

OSB="#@if windows
WIN_KEY=winval

#@endif
#@if posix
WIN_KEY=posixval

#@endif"

run_t1226_1() {
    local name="T1226-1: flat/no-marker input -> back-compat no-op (modulo LF)"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local input out
    input=$'KEY=value\nOTHER=foo'
    out=$(filter_os_blocks "$input" "win32")
    assert_contains "$name" "$out" "KEY=value"
    assert_contains "$name" "$out" "OTHER=foo"
    assert_not_contains "$name" "$out" "#@"
}

run_t1226_2() {
    local name="T1226-2: win32 selects windows block"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local out
    out=$(filter_os_blocks "$OSB" "win32")
    assert_contains "$name" "$out" "WIN_KEY=winval"
    assert_not_contains "$name" "$out" "WIN_KEY=posixval"
    assert_not_contains "$name" "$out" "#@if"
    assert_not_contains "$name" "$out" "#@endif"
}

run_t1226_3() {
    local name="T1226-3: linux selects posix block"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local out
    out=$(filter_os_blocks "$OSB" "linux")
    assert_contains "$name" "$out" "WIN_KEY=posixval"
    assert_not_contains "$name" "$out" "WIN_KEY=winval"
}

run_t1226_4() {
    local name="T1226-4: darwin selects posix block (darwin == posix)"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local out
    out=$(filter_os_blocks "$OSB" "darwin")
    assert_contains "$name" "$out" "WIN_KEY=posixval"
    assert_not_contains "$name" "$out" "WIN_KEY=winval"
}

run_t1226_5() {
    local name="T1226-5: marker lines stripped from output"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local input out
    input=$'#@if windows\nKEY=val\n\n#@endif\n'
    out=$(filter_os_blocks "$input" "win32")
    assert_contains "$name" "$out" "KEY=val"
    assert_not_contains "$name" "$out" "#@if"
    assert_not_contains "$name" "$out" "#@endif"
}

run_t1226_6() {
    local name="T1226-6: mixed — out-of-block lines pass through"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local input out
    input=$'SHARED=1\n#@if windows\nOS_KEY=win\n\n#@endif\nALSO_SHARED=2'
    out=$(filter_os_blocks "$input" "linux")
    assert_contains "$name" "$out" "SHARED=1"
    assert_contains "$name" "$out" "ALSO_SHARED=2"
    assert_not_contains "$name" "$out" "OS_KEY=win"
}

run_t1226_7() {
    local name="T1226-7: unterminated #@if at EOF — no throw, active block kept"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local input out rc
    input=$'#@if windows\nKEY=val\n'
    out=$(filter_os_blocks "$input" "win32"); rc=$?
    if [ $rc -ne 0 ]; then fail "$name (node threw, rc=$rc)"; return; fi
    assert_contains "$name" "$out" "KEY=val"
    assert_not_contains "$name" "$out" "#@if"
}

run_t1226_8() {
    local name="T1226-8: stray #@endif at depth 0 — dropped, no throw"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local input out rc
    input=$'KEY=val\n#@endif\n'
    out=$(filter_os_blocks "$input" "win32"); rc=$?
    if [ $rc -ne 0 ]; then fail "$name (node threw, rc=$rc)"; return; fi
    assert_contains "$name" "$out" "KEY=val"
    assert_not_contains "$name" "$out" "#@endif"
}

run_t1226_9() {
    local name="T1226-9: unknown token (#@if darwin on darwin) — suppressed"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local input out rc
    input=$'#@if darwin\nKEY=darwinval\n\n#@endif'
    out=$(filter_os_blocks "$input" "darwin"); rc=$?
    if [ $rc -ne 0 ]; then fail "$name (node threw, rc=$rc)"; return; fi
    assert_not_contains "$name" "$out" "KEY=darwinval"
}

run_t1226_10() {
    local name="T1226-10: CRLF line endings — block selected, no throw"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local input out rc
    input=$'#@if windows\r\nKEY=winval\r\n\r\n#@endif\r\n'
    out=$(filter_os_blocks "$input" "win32"); rc=$?
    if [ $rc -ne 0 ]; then fail "$name (node threw, rc=$rc)"; return; fi
    assert_contains "$name" "$out" "KEY=winval"
    assert_not_contains "$name" "$out" "#@if"
    assert_not_contains "$name" "$out" "#@endif"
}

# T1226-11: depth-aware model — a nested #@if inside an inactive block must NOT
# leak. State trace (win32): #@if posix (depth=1,suppress,suppressDepth=1) ->
# #@if windows (depth=2, unchanged) -> inner #@endif (depth 2>1, stay suppressed,
# depth=1) -> LEAK3 suppressed -> outer #@endif (depth 1==1, unsuppress, depth=0)
# -> SAFE=ok emitted.
run_t1226_11() {
    local name="T1226-11: nested #@if in inactive block does NOT leak (depth-aware)"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local input out rc
    input=$'#@if posix\nLEAK1=bad\n#@if windows\nLEAK2=bad\n#@endif\nLEAK3=bad\n#@endif\nSAFE=ok\n'
    out=$(filter_os_blocks "$input" "win32"); rc=$?
    if [ $rc -ne 0 ]; then fail "$name (node threw, rc=$rc)"; return; fi
    assert_not_contains "$name" "$out" "LEAK1"
    assert_not_contains "$name" "$out" "LEAK2"
    assert_not_contains "$name" "$out" "LEAK3"
    assert_contains "$name" "$out" "SAFE=ok"
}

# T1226-12: loadEnv() integration end-to-end with the LIVE process.platform.
# Write a temp .env with both a windows and a posix block (OS_KEY=win vs
# OS_KEY=posix), call loadEnv(tmpPath), and assert process.env.OS_KEY equals the
# value for the running platform. No platform injection — real process.platform.
run_t1226_12() {
    local name="T1226-12: loadEnv() end-to-end picks live-platform block"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    printf '#@if windows\nOS_KEY=win\n\n#@endif\n#@if posix\nOS_KEY=posix\n\n#@endif\n' > "$tmp/.env"
    local tmp_env_node="$tmp/.env"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_env_node="$(cygpath -m "$tmp/.env")"
    fi
    out=$(run_with_timeout 5 node -e "
const { loadEnv } = require(process.argv[1]);
const ok = loadEnv(process.argv[2]);
const expected = process.platform === 'win32' ? 'win' : 'posix';
process.stdout.write(JSON.stringify({ ok, got: process.env.OS_KEY || '', expected }));
" "$LOAD_ENV_NODE" "$tmp_env_node" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "$name (node threw, rc=$rc)"; return; fi
    if echo "$out" | grep -q '"ok":true' \
       && echo "$out" | grep -qE '"got":"(win|posix)"' \
       && [ "$(echo "$out" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const o=JSON.parse(s);process.stdout.write(o.got===o.expected?'1':'0')})" 2>/dev/null)" = "1" ]; then
        pass "$name"
    else
        fail "$name (out=$out)"
    fi
}

# T1226-13: empty-string input — filterOsBlocks("", "win32") returns exactly "".
# Mandated by skills/_shared/test-design.md (empty "" edge case); detail.md
# Risks & edge cases documents the "" -> "" contract.
run_t1226_13() {
    local name="T1226-13: empty-string input -> empty output"
    if [ "$HAS_FN" != "1" ]; then skip "$name (filterOsBlocks not yet exported — pending write-code)"; return; fi
    local out rc
    out=$(filter_os_blocks "" "win32"); rc=$?
    if [ $rc -ne 0 ]; then fail "$name (node threw, rc=$rc)"; return; fi
    assert_empty "$name" "$out"
}

run_t1226_1
run_t1226_2
run_t1226_3
run_t1226_4
run_t1226_5
run_t1226_6
run_t1226_7
run_t1226_8
run_t1226_9
run_t1226_10
run_t1226_11
run_t1226_12
run_t1226_13

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
