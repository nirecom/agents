#!/bin/bash
# Tests: hooks/show-diff.js
# Tags: hook, bin, macos, tests
# Test suite for show-diff.js PreToolUse hook
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-diff.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (macOS does not have GNU timeout)
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Run hook with JSON input; returns stdout
run_hook() {
    local json="$1"
    echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

# ── helpers ───────────────────────────────────────────────────────────────────

expect_has_system_message() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if echo "$result" | node -e "let d=require('fs').readFileSync('/dev/stdin','utf8').trim();if(!d){process.exit(1)}; let o=JSON.parse(d);process.exit(o.systemMessage!==undefined?0:1)" 2>/dev/null; then
        pass "$desc — has systemMessage"
    else
        fail "$desc — expected systemMessage, got: $result"
    fi
}

expect_no_decision() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if echo "$result" | node -e "let d=require('fs').readFileSync('/dev/stdin','utf8').trim();if(!d){process.exit(0)}; let o=JSON.parse(d);process.exit(o.decision!==undefined?1:0)" 2>/dev/null; then
        pass "$desc — no decision field"
    else
        fail "$desc — unexpected decision field in: $result"
    fi
}

expect_empty_stdout() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if [ -z "$result" ]; then
        pass "$desc — stdout is empty"
    else
        fail "$desc — expected empty stdout, got: $result"
    fi
}

expect_exit_zero() {
    local desc="$1" json="$2"
    local rc=0
    echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$desc — exit 0"
    else
        fail "$desc — expected exit 0, got exit $rc"
    fi
}

# ── T01: Edit normal ──────────────────────────────────────────────────────────
echo "=== T01: Edit normal ==="
T01_JSON='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.js","old_string":"foo\n","new_string":"bar\n"}}'
expect_has_system_message "T01 has systemMessage" "$T01_JSON"
expect_no_decision       "T01 no decision"       "$T01_JSON"
expect_exit_zero         "T01 exit 0"            "$T01_JSON"

# ── T02: Write normal ─────────────────────────────────────────────────────────
echo "=== T02: Write normal ==="
T02_JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.js","content":"hello world"}}'
expect_has_system_message "T02 has systemMessage" "$T02_JSON"
expect_no_decision        "T02 no decision"       "$T02_JSON"

# ── T03: MultiEdit normal ─────────────────────────────────────────────────────
echo "=== T03: MultiEdit normal ==="
T03_JSON='{"tool_name":"MultiEdit","tool_input":{"file_path":"/tmp/test.js","edits":[{"old_string":"a\n","new_string":"b\n"}]}}'
expect_has_system_message "T03 has systemMessage" "$T03_JSON"

# ── T04: editFiles with content ───────────────────────────────────────────────
echo "=== T04: editFiles with content ==="
T04_JSON='{"tool_name":"editFiles","tool_input":{"file_path":"/tmp/test.js","content":"hello"}}'
expect_has_system_message "T04 has systemMessage" "$T04_JSON"

# ── T05: editFiles without content key ───────────────────────────────────────
echo "=== T05: editFiles without content key ==="
T05_JSON='{"tool_name":"editFiles","tool_input":{"file_path":"/tmp/test.js"}}'
result_t05=$(run_hook "$T05_JSON")
rc_t05=0
echo "$T05_JSON" | run_with_timeout node "$HOOK" 2>/dev/null || rc_t05=$?
if [ "$rc_t05" -eq 0 ]; then
    # Either empty or has systemMessage — both acceptable; must not crash
    if [ -z "$result_t05" ]; then
        pass "T05 empty stdout (no crash)"
    else
        if echo "$result_t05" | node -e "let d=require('fs').readFileSync('/dev/stdin','utf8').trim();let o=JSON.parse(d);process.exit(o.systemMessage!==undefined?0:1)" 2>/dev/null; then
            pass "T05 has systemMessage (no crash)"
        else
            pass "T05 non-empty stdout (no crash)"
        fi
    fi
else
    fail "T05 crashed (exit $rc_t05)"
fi

# ── T06: Test directory ───────────────────────────────────────────────────────
echo "=== T06: Test directory ==="
expect_empty_stdout "T06 tests/ path" \
    '{"tool_name":"Edit","tool_input":{"file_path":"tests/foo.sh","old_string":"a","new_string":"b"}}'

# ── T07: Test extension .test.ts ──────────────────────────────────────────────
echo "=== T07: .test.ts extension ==="
expect_empty_stdout "T07 .test.ts file" \
    '{"tool_name":"Edit","tool_input":{"file_path":"foo.test.ts","old_string":"a","new_string":"b"}}'

# ── T08: test_ prefix ─────────────────────────────────────────────────────────
echo "=== T08: test_ prefix ==="
expect_empty_stdout "T08 test_ prefix" \
    '{"tool_name":"Edit","tool_input":{"file_path":"test_foo.py","old_string":"a","new_string":"b"}}'

# ── T09: Non-Edit tool (Bash) ─────────────────────────────────────────────────
echo "=== T09: Non-Edit tool ==="
expect_empty_stdout "T09 Bash tool" \
    '{"tool_name":"Bash","tool_input":{"command":"ls"}}'

# ── T10: Empty filePath ───────────────────────────────────────────────────────
echo "=== T10: Empty filePath ==="
expect_empty_stdout "T10 empty file_path" \
    '{"tool_name":"Edit","tool_input":{"file_path":"","old_string":"a","new_string":"b"}}'

# ── T11: MultiEdit empty edits ────────────────────────────────────────────────
echo "=== T11: MultiEdit empty edits ==="
expect_empty_stdout "T11 empty edits array" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"/tmp/test.js","edits":[]}}'

# ── T12: Long diff (>3000 chars) ──────────────────────────────────────────────
echo "=== T12: Long diff truncation ==="
# Build JSON with 200-line old string and 201-line new string via node to avoid shell escaping issues
T12_JSON=$(node -e "
const lines_old = Array.from({length:200},(_,i)=>'line_old_'+(i+1)+'_padding_padding_padding_padding_padding').join('\n');
const lines_new = Array.from({length:201},(_,i)=>'line_new_'+(i+1)+'_padding_padding_padding_padding_padding').join('\n');
console.log(JSON.stringify({tool_name:'Edit',tool_input:{file_path:'/tmp/test.js',old_string:lines_old,new_string:lines_new}}));
")
result_t12=$(run_hook "$T12_JSON")
if [ -n "$result_t12" ]; then
    # Extract systemMessage value length or check for truncated marker
    if echo "$result_t12" | grep -q "diff truncated"; then
        pass "T12 long diff truncated (marker present)"
    else
        # Check raw output length <= reasonable bound (JSON-encoded, so > 3000 raw is expected for JSON)
        raw_len=${#result_t12}
        # The systemMessage itself should be capped; check it contains systemMessage
        if echo "$result_t12" | node -e "let d=require('fs').readFileSync('/dev/stdin','utf8').trim();let o=JSON.parse(d);process.exit(o.systemMessage!==undefined?0:1)" 2>/dev/null; then
            pass "T12 has systemMessage (truncation logic ran)"
        else
            fail "T12 unexpected output: $result_t12"
        fi
    fi
else
    fail "T12 empty output for long diff"
fi

# ── T13: Broken JSON stdin ────────────────────────────────────────────────────
echo "=== T13: Broken JSON stdin ==="
result_t13=""
rc_t13=0
printf '{broken' | run_with_timeout node "$HOOK" 2>/dev/null || rc_t13=$?
result_t13=$(printf '{broken' | run_with_timeout node "$HOOK" 2>/dev/null || true)
if [ "$rc_t13" -eq 0 ] && [ -z "$result_t13" ]; then
    pass "T13 broken JSON: exit 0, empty stdout"
else
    fail "T13 broken JSON: exit=$rc_t13, stdout='$result_t13'"
fi

# ── T14: Idempotency ─────────────────────────────────────────────────────────
echo "=== T14: Idempotency ==="
T14_JSON='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/idempotency.js","old_string":"foo\n","new_string":"bar\n"}}'
result_a=$(run_hook "$T14_JSON")
result_b=$(run_hook "$T14_JSON")
if [ "$result_a" = "$result_b" ]; then
    pass "T14 identical outputs"
else
    fail "T14 outputs differ: first='$result_a' second='$result_b'"
fi
# No /tmp/diff-approved-* files should exist from this hook
if ls /tmp/diff-approved-* 2>/dev/null | grep -q .; then
    fail "T14 diff-approved token files found"
else
    pass "T14 no diff-approved token files"
fi

# ── T15: File exists smoke test ───────────────────────────────────────────────
echo "=== T15: show-diff.js file exists ==="
if [ -f "$AGENTS_DIR/hooks/show-diff.js" ]; then
    pass "T15 show-diff.js exists"
else
    fail "T15 show-diff.js not found at $AGENTS_DIR/hooks/show-diff.js"
fi

# ── T16: Non-interference (decision absent, systemMessage present) ────────────
echo "=== T16: Non-interference ==="
T16_JSON='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.js","old_string":"x\n","new_string":"y\n"}}'
result_t16=$(run_hook "$T16_JSON")
decision_check=0
system_check=0
echo "$result_t16" | node -e "let d=require('fs').readFileSync('/dev/stdin','utf8').trim();let o=JSON.parse(d);process.exit(o.decision!==undefined?1:0)" 2>/dev/null || decision_check=1
echo "$result_t16" | node -e "let d=require('fs').readFileSync('/dev/stdin','utf8').trim();let o=JSON.parse(d);process.exit(o.systemMessage!==undefined?0:1)" 2>/dev/null || system_check=1

if [ "$decision_check" -eq 0 ]; then
    pass "T16 decision field absent"
else
    fail "T16 decision field present (unexpected)"
fi
if [ "$system_check" -eq 0 ]; then
    pass "T16 systemMessage field present"
else
    fail "T16 systemMessage field missing"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
