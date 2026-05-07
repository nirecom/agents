#!/bin/bash
# tests/fix-heredoc-false-positive.sh
#
# Regression tests for the here-doc regex false-positive bug.
#
# Bug: /<<-?['"]?\w/ has no position anchor, so it matches the literal string
# "<<WORKFLOW_..." inside double-quoted echo arguments, classifying them as "write".
#
# Fix: /(?:^|[\s;|&])(?:\d*)<<-?['"]?\w/ requires the << token to be preceded
# by whitespace, semicolon, pipe, or start-of-string — not inside a quoted string.
#
# FP cases: currently classified "write" (wrong) — must be "read" after fix.
# HD cases: must remain "write" both before and after the fix.
# EX case:  existing test suite must still pass.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Convert to Windows-native path for Node.js require() on Windows (cygpath -m gives C:/... form)
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"

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

# Classify a command. Prints "read", "write", or "ERROR: ...".
classify_cmd() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const fn = m.classify;
        const arg = process.argv[1];
        let v;
        if (arg === '__NULL__') v = null;
        else if (arg === '__UNDEF__') v = undefined;
        else if (arg === '__NUM__') v = 123;
        else v = arg;
        console.log(fn(v));
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$1" 2>/dev/null
}

assert_classify() {
    local desc="$1" cmd="$2" expected="$3"
    local got
    got="$(classify_cmd "$cmd")"
    if [ "$got" = "$expected" ]; then
        pass "$desc -> $expected"
    else
        fail "$desc: expected '$expected', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

# ============================================================
# FP cases — false positives in old code.
# These MUST classify as "read" (post-fix contract).
# They currently fail (old code returns "write") — that is expected.
# ============================================================

test_fp_cases() {
    echo "=== FP cases (must be read after fix) ==="

    # FP-1: double-quoted WORKFLOW sentinel inside echo
    assert_classify \
        'FP-1: echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"' \
        'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"' \
        "read"

    # FP-2: single-quoted WORKFLOW sentinel inside echo
    assert_classify \
        "FP-2: echo '<<WORKFLOW_COMPLETE>>'" \
        "echo '<<WORKFLOW_COMPLETE>>'" \
        "read"

    # FP-3: single-quoted sentinel as printf argument
    assert_classify \
        "FP-3: printf '%s\n' '<<WORKFLOW_COMPLETE>>'" \
        "printf '%s\n' '<<WORKFLOW_COMPLETE>>'" \
        "read"

    # FP-4: double-quoted sentinel as printf argument
    assert_classify \
        'FP-4: printf "%s\n" "<<WORKFLOW_COMPLETE>>"' \
        'printf "%s\n" "<<WORKFLOW_COMPLETE>>"' \
        "read"

    # FP-5: another WORKFLOW variant
    assert_classify \
        'FP-5: echo "<<WORKFLOW_BRANCHING_COMPLETE>>"' \
        'echo "<<WORKFLOW_BRANCHING_COMPLETE>>"' \
        "read"
}

# ============================================================
# HD regression cases — real here-docs must stay "write".
# These must pass both before and after the fix.
# ============================================================

test_hd_cases() {
    echo "=== HD regression cases (must remain write) ==="

    # HD-1: basic heredoc (multiline)
    assert_classify \
        'HD-1: cat <<EOF (multiline)' \
        'cat <<EOF
hello
EOF' \
        "write"

    # HD-2: strip-tabs heredoc (<<-)
    assert_classify \
        'HD-2: cat <<-EOF' \
        'cat <<-EOF
x
EOF' \
        "write"

    # HD-3: single-quoted delimiter (no interpolation)
    assert_classify \
        "HD-3: cat <<'EOF'" \
        "cat <<'EOF'
hello
EOF" \
        "write"

    # HD-4: double-quoted delimiter
    assert_classify \
        'HD-4: cat <<"EOF"' \
        'cat <<"EOF"
hello
EOF' \
        "write"

    # HD-5: explicit FD number before << at start of command
    assert_classify \
        'HD-5: 0<<EOF (FD with heredoc at start)' \
        '0<<EOF
x
EOF' \
        "write"
}

# ============================================================
# EX — existing test suite must still pass entirely.
# ============================================================

test_existing_suite() {
    echo "=== EX: existing test suite ==="
    local existing_test
    existing_test="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-parallel-sessions-worktree-bash-patterns.sh"
    if [ ! -f "$existing_test" ]; then
        fail "EX: existing test file not found: $existing_test"
        return
    fi
    local exit_code
    run_with_timeout 120 bash "$existing_test"
    exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        pass "EX: existing suite exited 0"
    else
        fail "EX: existing suite exited $exit_code (regression)"
    fi
}

# ============================================================
# Edge cases — variations on the sentinel pattern
# ============================================================

test_edge_cases() {
    echo "=== Edge cases ==="

    # Sentinel at start of a compound command (read half)
    assert_classify \
        'EDGE-1: echo "<<WORKFLOW_X>>" && git status' \
        'echo "<<WORKFLOW_X>>" && git status' \
        "read"

    # Sentinel followed by write command — compound should be write
    assert_classify \
        'EDGE-2: echo "<<WORKFLOW_X>>" && rm foo' \
        'echo "<<WORKFLOW_X>>" && rm foo' \
        "write"

    # Multiple sentinels, no heredoc
    assert_classify \
        'EDGE-3: echo "<<A>>" && echo "<<B>>"' \
        'echo "<<A>>" && echo "<<B>>"' \
        "read"

    # Bare << at start of command (not inside quotes) — still a heredoc token
    assert_classify \
        'EDGE-4: <<WORD at start of line' \
        '<<WORD
content
WORD' \
        "write"
}

# ============================================================
# Idempotency — calling classify twice gives the same result
# ============================================================

test_idempotency() {
    echo "=== Idempotency ==="
    local a b
    a="$(classify_cmd 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"')"
    b="$(classify_cmd 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"')"
    if [ "$a" = "$b" ]; then
        pass "IDEM-1: classify is idempotent for FP sentinel"
    else
        fail "IDEM-1: classify not idempotent: first=$a second=$b"
    fi

    a="$(classify_cmd 'cat <<EOF
hello
EOF')"
    b="$(classify_cmd 'cat <<EOF
hello
EOF')"
    if [ "$a" = "$b" ] && [ "$a" = "write" ]; then
        pass "IDEM-2: classify is idempotent for heredoc (write)"
    else
        fail "IDEM-2: classify not idempotent for heredoc: first=$a second=$b"
    fi
}

# ============================================================
# Security — sentinels in adversarial positions must not bypass write detection
# ============================================================

test_security_cases() {
    echo "=== Security cases ==="

    # Sentinel text in first arg, write op later — must still be write
    assert_classify \
        'SEC-1: sentinel + rm (compound should be write)' \
        'echo "<<WORKFLOW_COMPLETE>>" ; rm -rf /tmp/x' \
        "write"

    # Sentinel text injected before git commit
    assert_classify \
        'SEC-2: sentinel + git commit (compound should be write)' \
        'echo "<<WORKFLOW_COMPLETE>>" && git commit -m x' \
        "write"

    # Ensure <<< (here-string) is still write — pattern is different from <<
    assert_classify \
        'SEC-3: here-string <<< still write' \
        'grep <<<"input"' \
        "write"
}

# ============================================================
# Run all test groups
# ============================================================

test_fp_cases
test_hd_cases
test_existing_suite
test_edge_cases
test_idempotency
test_security_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
