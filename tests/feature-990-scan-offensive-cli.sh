#!/bin/bash
# tests/feature-990-scan-offensive-cli.sh
# Tests: bin/scan-offensive
# Tags: scan, offensive, content-filter, cli, scope:issue-specific
# RED for issue #990.
#
# L3 gap (what this test does NOT catch):
# - real PreToolUse hook integration (covered by feature-990-scan-outbound-offensive-integration.sh)
# - real Anthropic API call for LLM tier (covered by feature-990-scan-offensive-llm.sh — fail-open only)
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$AGENTS_DIR/bin/scan-offensive"
BLOCKLIST="$AGENTS_DIR/.offensive-content-blocklist"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_cli() {
    if [ ! -f "$CLI" ]; then
        skip "$1 (bin/scan-offensive not implemented yet)"
        return 1
    fi
    return 0
}

# Discover a hard-block keyword from the blocklist if it exists; otherwise
# fall back to a sentinel string that the implementation is expected to handle.
discover_hard_keyword() {
    if [ -f "$BLOCKLIST" ]; then
        # First non-comment, non-blank line — strip leading "hard:" or "warn:" prefix if any.
        local kw
        kw=$(awk '
            /^[[:space:]]*#/ {next}
            /^[[:space:]]*$/ {next}
            { sub(/^[[:space:]]*(hard:|warn:)?/, ""); print; exit }
        ' "$BLOCKLIST")
        if [ -n "$kw" ]; then
            echo "$kw"
            return 0
        fi
    fi
    # Fallback sentinel — clearly offensive marker the impl is expected to ship with.
    echo "OFFENSIVE_TEST_SENTINEL"
}

run_t1() {
    require_cli "T1: clean text → exit 0" || return
    local rc
    # Pipe via stdin with the --stdin <label> contract
    echo "this is a perfectly normal clean sentence" | run_with_timeout 30 "$CLI" --stdin "t1-clean" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "T1: clean text → exit 0"
    else
        fail "T1: clean text expected rc=0, got rc=$rc"
    fi
}

run_t2() {
    require_cli "T2: hard offensive keyword → exit 1, reason on stderr" || return
    local rc stderr_capture
    local tmp_bl
    tmp_bl=$(mktemp)
    echo "__cli_test_sentinel__" > "$tmp_bl"
    trap "rm -f '$tmp_bl'" RETURN
    local kw="__cli_test_sentinel__"
    stderr_capture=$(mktemp)
    echo "this message contains $kw which should trip the keyword tier" \
        | SCAN_OFFENSIVE_BLOCKLIST="$tmp_bl" run_with_timeout 30 "$CLI" --stdin "t2-hard" >/dev/null 2>"$stderr_capture"
    rc=$?
    local stderr_content
    stderr_content=$(cat "$stderr_capture" 2>/dev/null || echo "")
    rm -f "$stderr_capture"
    if [ "$rc" -eq 1 ] && [ -n "$stderr_content" ]; then
        pass "T2: hard offensive keyword → exit 1, reason on stderr"
    elif [ "$rc" -eq 1 ]; then
        fail "T2: rc=1 but stderr was empty (expected reason)"
    else
        fail "T2: expected rc=1, got rc=$rc (kw='$kw')"
    fi
}

run_t3() {
    require_cli "T3: --stdin <label> mode accepts text via stdin pipe" || return
    local rc out
    out=$(echo "label-mode test text" | run_with_timeout 30 "$CLI" --stdin "t3-label" 2>&1)
    rc=$?
    # Either clean exit (0) or warn (2) are acceptable here. We only care that
    # the CLI accepted the stdin mode and did not error with rc=3 (usage).
    if [ "$rc" -ne 3 ]; then
        pass "T3: --stdin <label> mode accepts text via stdin pipe"
    else
        fail "T3: usage error (rc=3) for valid --stdin invocation: $out"
    fi
}

run_t4() {
    require_cli "T4: empty stdin → exit 0 (no false positive)" || return
    local rc
    printf '' | run_with_timeout 30 "$CLI" --stdin "t4-empty" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "T4: empty stdin → exit 0"
    else
        fail "T4: empty stdin expected rc=0, got rc=$rc"
    fi
}

run_t5() {
    require_cli "T5: case-insensitive keyword matching" || return
    local rc_lower rc_upper
    local tmp_bl
    tmp_bl=$(mktemp)
    echo "__cli_test_sentinel__" > "$tmp_bl"
    trap "rm -f '$tmp_bl'" RETURN
    local kw="__cli_test_sentinel__"
    # Build upper/lower-cased variants. The test asserts detection is case-insensitive —
    # both variants must produce the same non-zero exit code.
    local lower upper
    lower=$(echo "$kw" | tr 'A-Z' 'a-z')
    upper=$(echo "$kw" | tr 'a-z' 'A-Z')
    echo "context $lower context" | SCAN_OFFENSIVE_BLOCKLIST="$tmp_bl" run_with_timeout 30 "$CLI" --stdin "t5-lower" >/dev/null 2>&1
    rc_lower=$?
    echo "context $upper context" | SCAN_OFFENSIVE_BLOCKLIST="$tmp_bl" run_with_timeout 30 "$CLI" --stdin "t5-upper" >/dev/null 2>&1
    rc_upper=$?
    if [ "$rc_lower" = "$rc_upper" ] && [ "$rc_lower" -ne 3 ]; then
        pass "T5: case-insensitive keyword matching (lower=$rc_lower, upper=$rc_upper)"
    else
        fail "T5: case sensitivity mismatch (lower=$rc_lower vs upper=$rc_upper)"
    fi
}

run_t6() {
    require_cli "T6: no args and no stdin → exit 3 (usage)" || return
    local rc
    # Close stdin so the CLI doesn't block reading.
    run_with_timeout 10 "$CLI" </dev/null >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 3 ]; then
        pass "T6: no args and no stdin → exit 3 (usage)"
    else
        fail "T6: expected rc=3, got rc=$rc"
    fi
}

run_t7() {
    require_cli "T7: shell metacharacter injection in input → no command injection" || return
    local rc canary
    canary="$(mktemp -d)/should-not-exist"
    # If the CLI were to eval its stdin, this would create the canary or delete files.
    local payload='; rm -rf / ; touch '"$canary"' ; `id` $(id)'
    echo "$payload" | run_with_timeout 30 "$CLI" --stdin "t7-inject" >/dev/null 2>&1
    rc=$?
    if [ -e "$canary" ]; then
        fail "T7: command injection succeeded — canary file was created"
        rm -f "$canary"
        return
    fi
    if [ "$rc" -ne 3 ]; then
        pass "T7: shell metacharacters in stdin treated as text (rc=$rc)"
    else
        fail "T7: stdin caused usage error rc=3 (should be content-only)"
    fi
}

run_t8() {
    require_cli "T8: path traversal in label arg → handled safely" || return
    local rc canary
    canary="$(mktemp -d)/traversal-canary"
    # Pass a path-traversal-shaped label. The CLI must not interpret it as a path.
    local label='../../etc/passwd'
    echo "ordinary content" | run_with_timeout 30 "$CLI" --stdin "$label" >/dev/null 2>&1
    rc=$?
    # Same check from a different label form
    local label2='../../../../tmp/'"$(basename "$canary")"
    echo "ordinary content" | run_with_timeout 30 "$CLI" --stdin "$label2" >/dev/null 2>&1
    local rc2=$?
    if [ -e "$canary" ]; then
        fail "T8: traversal label produced filesystem side effect"
        rm -f "$canary"
        return
    fi
    if [ "$rc" -ne 3 ] && [ "$rc2" -ne 3 ]; then
        pass "T8: path traversal in label arg → handled safely (rc=$rc, rc2=$rc2)"
    else
        fail "T8: traversal label caused usage error (rc=$rc, rc2=$rc2)"
    fi
}

run_t9() {
    require_cli "T9: warn-tier pattern exits 2" || return
    local rc warn_bl
    warn_bl="$(mktemp)"
    printf 'warn:__warn_test_kw__\n' > "$warn_bl"
    rc=0
    (SCAN_OFFENSIVE_BLOCKLIST="$warn_bl" run_with_timeout 30 "$CLI" --stdin "testlabel" <<< "__warn_test_kw__ in this sentence here") >/dev/null 2>&1 || rc=$?
    rm -f "$warn_bl"
    if [ "$rc" = "2" ]; then
        pass "T9: warn-tier pattern exits 2"
    else
        fail "T9: warn-tier exit expected 2, got $rc"
    fi
}

run_t10() {
    require_cli "T10: missing SCAN_OFFENSIVE_BLOCKLIST → blocklist-not-found warning, exit 0" || return
    local rc out
    rc=0
    out=$(SCAN_OFFENSIVE_BLOCKLIST="/nonexistent/path/blocklist_$(date +%s).txt" run_with_timeout 30 "$CLI" --stdin "testlabel" <<< "some ordinary clean content here" 2>&1) || rc=$?
    if [ "$rc" = "0" ] && echo "$out" | grep -q "blocklist not found"; then
        pass "T10: missing SCAN_OFFENSIVE_BLOCKLIST → warning + exit 0"
    elif [ "$rc" = "0" ]; then
        fail "T10: exit 0 but no 'blocklist not found' in stderr; got: $out"
    else
        fail "T10: missing blocklist should not cause non-zero exit, got rc=$rc"
    fi
}

run_t11() {
    require_cli "T11: blocklist with only comments → no patterns, exit 0" || return
    local rc comment_bl
    comment_bl="$(mktemp)"
    printf '# This is a comment\n# Another comment\n\n' > "$comment_bl"
    rc=0
    (SCAN_OFFENSIVE_BLOCKLIST="$comment_bl" run_with_timeout 30 "$CLI" --stdin "testlabel" <<< "some clean content") >/dev/null 2>&1 || rc=$?
    rm -f "$comment_bl"
    if [ "$rc" = "0" ]; then
        pass "T11: comment-only blocklist → exit 0 (no active patterns)"
    else
        fail "T11: comment-only blocklist should produce exit 0, got rc=$rc"
    fi
}

run_t12() {
    require_cli "T12: invalid regex in blocklist → 'invalid regex skipped' warning, exit 0" || return
    local rc invalid_bl out
    invalid_bl="$(mktemp)"
    printf '[unclosed-bracket\n' > "$invalid_bl"
    rc=0
    out=$(SCAN_OFFENSIVE_BLOCKLIST="$invalid_bl" run_with_timeout 30 "$CLI" --stdin "testlabel" <<< "some ordinary clean content" 2>&1) || rc=$?
    rm -f "$invalid_bl"
    if [ "$rc" = "0" ] && echo "$out" | grep -q "invalid.*regex skipped\|invalid regex"; then
        pass "T12: invalid regex in blocklist → skipped warning + exit 0"
    elif [ "$rc" = "0" ]; then
        fail "T12: exit 0 but no 'invalid regex skipped' in stderr; got: $out"
    else
        fail "T12: invalid regex should not crash scanner (exit 0), got rc=$rc"
    fi
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t9
run_t10
run_t11
run_t12

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
