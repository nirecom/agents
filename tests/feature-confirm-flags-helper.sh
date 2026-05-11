#!/bin/bash
# Tests for bin/get-config-var helper used by confirm-flags feature.
#
# Pre-implementation: ALL tests are expected to FAIL with "file/command not
# found" because bin/get-config-var has not been written yet. Once the
# implementation lands, these tests must pass.
#
# Test categories (see rules/test.md):
#   - Unit:         --is-off matrix (truthy / falsy), missing arg
#   - Narrow:       tmpdir .env via AGENTS_CONFIG_DIR, process.env precedence,
#                   default fallback, no-.env-token check, clean-PATH lookup
#   - Edge:         quoted values, spaces in AGENTS_CONFIG_DIR
#   - Security:     path traversal in AGENTS_CONFIG_DIR, shell metachars in
#                   arg name, idempotency of repeated calls
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/bin/get-config-var"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Windows-compatible tmpdir (matches existing tests' pattern)
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Always isolate AGENTS_CONFIG_DIR per case unless overridden.
# Some tests deliberately export it; reset between cases.
unset_isolated_env() {
    unset AGENTS_CONFIG_DIR
    unset CONFIRM_OUTLINE
    unset CONFIRM_DETAIL
    unset CONFIRM_TESTS
    unset CONFIRM_WORKTREE
    unset GETCFG_TESTVAR
}

# Helper: invoke and capture exit code without aborting the script.
# Usage: capture_exit <expected_exit> <test_name> -- <cmd> [args...]
capture_exit() {
    local expected="$1" name="$2"; shift 2
    [ "$1" = "--" ] && shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "$expected" ]; then
        pass "$name"
    else
        fail "$name (expected exit $expected, got $rc)"
    fi
}

# ---------------------------------------------------------------------------
# Unit: --is-off truthy values (exit 0)
# ---------------------------------------------------------------------------
echo "=== Unit: --is-off truthy (exit 0) ==="
for v in off OFF Off 0 false no disabled; do
    unset_isolated_env
    export GETCFG_TESTVAR="$v"
    capture_exit 0 "is-off exits 0 for '$v'" -- run_with_timeout "$HELPER" --is-off GETCFG_TESTVAR on
done

# ---------------------------------------------------------------------------
# Unit: --is-off non-OFF values (exit 1)
# ---------------------------------------------------------------------------
echo "=== Unit: --is-off non-OFF (exit 1) ==="
# 'on' explicit
unset_isolated_env; export GETCFG_TESTVAR="on"
capture_exit 1 "is-off exits 1 for 'on'" -- run_with_timeout "$HELPER" --is-off GETCFG_TESTVAR on

# empty value — exporting empty string in bash
unset_isolated_env; export GETCFG_TESTVAR=""
capture_exit 1 "is-off exits 1 for empty value" -- run_with_timeout "$HELPER" --is-off GETCFG_TESTVAR on

# unknown value
unset_isolated_env; export GETCFG_TESTVAR="maybe"
capture_exit 1 "is-off exits 1 for 'maybe'" -- run_with_timeout "$HELPER" --is-off GETCFG_TESTVAR on

# leading space — NO trim, so " off" != "off"
unset_isolated_env; export GETCFG_TESTVAR=" off"
capture_exit 1 "is-off exits 1 for ' off' (leading space, no trim)" -- run_with_timeout "$HELPER" --is-off GETCFG_TESTVAR on

# trailing space
unset_isolated_env; export GETCFG_TESTVAR="off "
capture_exit 1 "is-off exits 1 for 'off ' (trailing space, no trim)" -- run_with_timeout "$HELPER" --is-off GETCFG_TESTVAR on

# ---------------------------------------------------------------------------
# Unit: --is-off produces no stdout
# ---------------------------------------------------------------------------
echo "=== Unit: --is-off has empty stdout ==="
unset_isolated_env; export GETCFG_TESTVAR="off"
out=$(run_with_timeout "$HELPER" --is-off GETCFG_TESTVAR on 2>/dev/null || true)
if [ -z "$out" ]; then
    pass "is-off mode produces empty stdout"
else
    fail "is-off mode stdout should be empty, got: '$out'"
fi

# ---------------------------------------------------------------------------
# Unit: missing arg → exit 2 + stderr contains "usage"
# ---------------------------------------------------------------------------
echo "=== Unit: missing arg → exit 2 + 'usage' ==="
unset_isolated_env
err=$(run_with_timeout "$HELPER" 2>&1 >/dev/null || true)
rc=0
run_with_timeout "$HELPER" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "2" ]; then
    pass "no-arg exits 2"
else
    fail "no-arg should exit 2, got $rc"
fi
if echo "$err" | grep -qi "usage"; then
    pass "no-arg stderr contains 'usage'"
else
    fail "no-arg stderr should contain 'usage', got: '$err'"
fi

# ---------------------------------------------------------------------------
# Narrow: tmpdir .env + AGENTS_CONFIG_DIR → value-mode prints value
# ---------------------------------------------------------------------------
echo "=== Narrow: AGENTS_CONFIG_DIR + .env value lookup ==="
NDIR1="$TMPDIR_BASE/cfg1"
mkdir -p "$NDIR1"
# Write .env via printf to avoid the .env block hook on Edit/Read tools
printf 'CONFIRM_OUTLINE=off\nCONFIRM_DETAIL=on\n' > "$NDIR1/.env"
unset_isolated_env
export AGENTS_CONFIG_DIR="$NDIR1"
val=$(run_with_timeout "$HELPER" CONFIRM_OUTLINE on 2>/dev/null || true)
if [ "$val" = "off" ]; then
    pass "value-mode reads .env: CONFIRM_OUTLINE=off"
else
    fail "value-mode should print 'off', got: '$val'"
fi
val=$(run_with_timeout "$HELPER" CONFIRM_DETAIL off 2>/dev/null || true)
if [ "$val" = "on" ]; then
    pass "value-mode reads .env: CONFIRM_DETAIL=on"
else
    fail "value-mode should print 'on', got: '$val'"
fi

# ---------------------------------------------------------------------------
# Narrow: process.env wins over .env
# ---------------------------------------------------------------------------
echo "=== Narrow: process.env precedence over .env ==="
NDIR2="$TMPDIR_BASE/cfg2"
mkdir -p "$NDIR2"
printf 'CONFIRM_OUTLINE=off\n' > "$NDIR2/.env"
unset_isolated_env
export AGENTS_CONFIG_DIR="$NDIR2"
export CONFIRM_OUTLINE="on"
val=$(run_with_timeout "$HELPER" CONFIRM_OUTLINE off 2>/dev/null || true)
if [ "$val" = "on" ]; then
    pass "process.env wins over .env"
else
    fail "process.env should override .env, got: '$val' (expected 'on')"
fi

# ---------------------------------------------------------------------------
# Narrow: default fallback — missing key / missing .env / empty .env
# ---------------------------------------------------------------------------
echo "=== Narrow: default fallback ==="
# Missing key in .env
NDIR3="$TMPDIR_BASE/cfg3"
mkdir -p "$NDIR3"
printf 'OTHER_KEY=foo\n' > "$NDIR3/.env"
unset_isolated_env
export AGENTS_CONFIG_DIR="$NDIR3"
val=$(run_with_timeout "$HELPER" CONFIRM_OUTLINE on 2>/dev/null || true)
if [ "$val" = "on" ]; then
    pass "missing key falls back to default arg"
else
    fail "missing key should print default 'on', got: '$val'"
fi

# Missing .env file
NDIR4="$TMPDIR_BASE/cfg4-no-env"
mkdir -p "$NDIR4"
unset_isolated_env
export AGENTS_CONFIG_DIR="$NDIR4"
val=$(run_with_timeout "$HELPER" CONFIRM_OUTLINE on 2>/dev/null || true)
if [ "$val" = "on" ]; then
    pass "missing .env falls back to default arg"
else
    fail "missing .env should print default, got: '$val'"
fi

# Empty .env file
NDIR5="$TMPDIR_BASE/cfg5-empty"
mkdir -p "$NDIR5"
: > "$NDIR5/.env"
unset_isolated_env
export AGENTS_CONFIG_DIR="$NDIR5"
val=$(run_with_timeout "$HELPER" CONFIRM_OUTLINE off 2>/dev/null || true)
if [ "$val" = "off" ]; then
    pass "empty .env falls back to default arg"
else
    fail "empty .env should print default 'off', got: '$val'"
fi

# ---------------------------------------------------------------------------
# Narrow: command string contains no `.env` token (block-dotenv compatibility)
# ---------------------------------------------------------------------------
echo "=== Narrow: command pattern has no '.env' token ==="
CMD_STRING='get-config-var --is-off CONFIRM_OUTLINE on && echo OFF || echo ON'
# Regex check: look for `.env` as a standalone path-like token.
# block-dotenv tokenizes and checks isDotenvPath on basename — any `.env`
# at a word boundary in the command would be flagged.
if echo "$CMD_STRING" | grep -E '(^|[[:space:]/])\.env([[:space:]/]|$|\.)' >/dev/null 2>&1; then
    fail "command string contains '.env' token: $CMD_STRING"
else
    pass "command string is free of '.env' tokens"
fi

# ---------------------------------------------------------------------------
# Narrow: clean PATH lookup (~/.local/bin)
# ---------------------------------------------------------------------------
echo "=== Narrow: clean-PATH lookup via ~/.local/bin ==="
LOCAL_BIN="$HOME/.local/bin/get-config-var"
if [ ! -e "$LOCAL_BIN" ]; then
    echo "SKIP: ~/.local/bin/get-config-var not installed yet (dotfileslink hasn't run)"
else
    unset_isolated_env
    # Use a minimal PATH that includes only ~/.local/bin and /usr/bin
    rc=0
    PATH="$HOME/.local/bin:/usr/bin" run_with_timeout bash -c 'command -v get-config-var >/dev/null' >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "0" ]; then
        pass "get-config-var is on PATH via ~/.local/bin"
    else
        fail "get-config-var not found with clean PATH=~/.local/bin:/usr/bin"
    fi
fi

# ---------------------------------------------------------------------------
# Edge: quoted .env value
# ---------------------------------------------------------------------------
echo "=== Edge: quoted .env value ==="
NDIR6="$TMPDIR_BASE/cfg6-quoted"
mkdir -p "$NDIR6"
printf 'CONFIRM_TESTS="off"\n' > "$NDIR6/.env"
unset_isolated_env
export AGENTS_CONFIG_DIR="$NDIR6"
capture_exit 0 "quoted value 'off' parses as OFF" -- run_with_timeout "$HELPER" --is-off CONFIRM_TESTS on

# ---------------------------------------------------------------------------
# Edge: AGENTS_CONFIG_DIR path containing spaces
# ---------------------------------------------------------------------------
echo "=== Edge: AGENTS_CONFIG_DIR with spaces ==="
NDIR7="$TMPDIR_BASE/cfg dir with spaces"
mkdir -p "$NDIR7"
printf 'CONFIRM_OUTLINE=off\n' > "$NDIR7/.env"
unset_isolated_env
export AGENTS_CONFIG_DIR="$NDIR7"
val=$(run_with_timeout "$HELPER" CONFIRM_OUTLINE on 2>/dev/null || true)
if [ "$val" = "off" ]; then
    pass "AGENTS_CONFIG_DIR with spaces resolves"
else
    fail "AGENTS_CONFIG_DIR with spaces should resolve, got: '$val'"
fi

# ---------------------------------------------------------------------------
# Security: path traversal in AGENTS_CONFIG_DIR
# ---------------------------------------------------------------------------
echo "=== Security: path traversal in AGENTS_CONFIG_DIR ==="
unset_isolated_env
export AGENTS_CONFIG_DIR="../../etc"
rc=0
out=$(run_with_timeout "$HELPER" CONFIRM_OUTLINE on 2>&1) || rc=$?
# Should fall back silently to default, no error/leakage; default 'on' printed
if [ "$rc" = "0" ] && [ "$out" = "on" ]; then
    pass "path traversal silently falls back to default"
else
    fail "path traversal should silently default to 'on' (rc=$rc, out='$out')"
fi
# Also ensure stderr did not leak system paths (no /etc/passwd-style output)
if echo "$out" | grep -E '(/etc/|root:|bin/bash)' >/dev/null 2>&1; then
    fail "traversal leaked system path content"
else
    pass "traversal did not leak system content"
fi

# ---------------------------------------------------------------------------
# Security: shell metacharacters in arg name
# ---------------------------------------------------------------------------
echo "=== Security: shell metachars in arg name ==="
unset_isolated_env
# semicolon should not start a subshell — must be rejected or treated as a
# literal arg name (which won't match anything and falls back to default)
rc=0
out=$(run_with_timeout "$HELPER" 'CONFIRM_OUTLINE; echo INJECTED' on 2>&1) || rc=$?
if echo "$out" | grep -q "INJECTED"; then
    fail "semicolon injection executed (output: '$out')"
else
    pass "semicolon in arg name is not interpreted as shell command"
fi
# Backticks
out=$(run_with_timeout "$HELPER" 'CONFIRM_OUTLINE`echo INJ`' on 2>&1) || true
if echo "$out" | grep -q "INJ"; then
    fail "backtick injection executed (output: '$out')"
else
    pass "backticks in arg name are not interpreted"
fi

# ---------------------------------------------------------------------------
# Security idempotency: two consecutive calls yield same result
# ---------------------------------------------------------------------------
echo "=== Security: idempotency ==="
NDIR8="$TMPDIR_BASE/cfg8-idem"
mkdir -p "$NDIR8"
printf 'CONFIRM_OUTLINE=off\n' > "$NDIR8/.env"
unset_isolated_env
export AGENTS_CONFIG_DIR="$NDIR8"
out1=$(run_with_timeout "$HELPER" --is-off CONFIRM_OUTLINE on 2>&1; echo "EXIT=$?")
out2=$(run_with_timeout "$HELPER" --is-off CONFIRM_OUTLINE on 2>&1; echo "EXIT=$?")
if [ "$out1" = "$out2" ]; then
    pass "two consecutive calls produce identical output + exit"
else
    fail "idempotency broken: '$out1' vs '$out2'"
fi

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
