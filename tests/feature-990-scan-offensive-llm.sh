#!/bin/bash
# tests/feature-990-scan-offensive-llm.sh
# Tests: bin/scan-offensive
# Tags: scan, offensive, llm, fail-open, scope:issue-specific
# RED for issue #990.
#
# L3 gap (what this test does NOT catch):
# - real Anthropic API call success (intentionally out of scope; cost & flakiness)
# - LLM verdict behavior on borderline content (requires live API)
# - prompt injection in input content overriding the classification verdict (real API only; prompt uses --- fencing but not formally tested)
# - LLM warn-verdict path (exit 2 via LLM verdict="warn") — requires live API
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight.

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

discover_hard_keyword() {
    if [ -f "$BLOCKLIST" ]; then
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
    echo "OFFENSIVE_TEST_SENTINEL"
}

# Exact expected stderr message per spec
EXPECTED_LLM_SKIP_MSG="scan-offensive: LLM stage skipped (ANTHROPIC_API_KEY not set) — keyword-only scan"

run_t1() {
    require_cli "T1: no API key + clean text → exit 0 (keyword-clean passes through)" || return
    local rc
    rc=0
    echo "a clean and unremarkable sentence" \
        | (unset ANTHROPIC_API_KEY; run_with_timeout 30 "$CLI" --stdin "t1-llm-skip") >/dev/null 2>&1 \
        || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "T1: no API key + clean text → exit 0"
    else
        fail "T1: expected rc=0 with no API key on clean text, got rc=$rc"
    fi
}

run_t2() {
    require_cli "T2: no API key → stderr contains exact LLM skip warning" || return
    local stderr_file rc
    stderr_file=$(mktemp)
    # Text must be >= 50 chars to reach the LLM stage (and thus emit the skip warning).
    echo "a clean and completely unremarkable sentence with plenty of length" \
        | (unset ANTHROPIC_API_KEY; run_with_timeout 30 "$CLI" --stdin "t2-llm-skip-msg") >/dev/null 2>"$stderr_file"
    rc=$?
    local stderr_content
    stderr_content=$(cat "$stderr_file" 2>/dev/null || echo "")
    rm -f "$stderr_file"
    # Match the literal expected message
    if echo "$stderr_content" | grep -qF "$EXPECTED_LLM_SKIP_MSG"; then
        pass "T2: stderr contains exact LLM skip warning"
    else
        fail "T2: expected stderr to contain '$EXPECTED_LLM_SKIP_MSG', got: $stderr_content (rc=$rc)"
    fi
}

run_t3() {
    require_cli "T3: no API key + keyword hard-block → still exit 1 (keyword tier runs)" || return
    local rc
    local tmp_blocklist
    tmp_blocklist=$(mktemp)
    trap "rm -f '$tmp_blocklist'" RETURN
    echo "__llm_test_kw__" > "$tmp_blocklist"
    rc=0
    echo "this contains __llm_test_kw__ inline" \
        | (unset ANTHROPIC_API_KEY; SCAN_OFFENSIVE_BLOCKLIST="$tmp_blocklist" run_with_timeout 30 "$CLI" --stdin "t3-llm-skip-but-keyword") >/dev/null 2>&1 \
        || rc=$?
    if [ "$rc" -eq 1 ]; then
        pass "T3: no API key + keyword hard-block → exit 1"
    else
        fail "T3: expected rc=1 (keyword tier still runs), got rc=$rc"
    fi
}

run_t4() {
    require_cli "T4: LLM API error → fail-open (exit 0, stderr LLM stage error warning)" || return
    local rc out
    rc=0
    out=$(ANTHROPIC_API_KEY="test-invalid-key-for-unit-test" run_with_timeout 30 "$CLI" --stdin "testlabel" <<< "This is a sufficiently long sentence to trigger the LLM classification tier in the scanner." 2>&1) || rc=$?
    if [ "$rc" = "0" ] && echo "$out" | grep -qi "LLM stage error"; then
        pass "T4: LLM API error → fail-open (exit 0, stderr LLM stage error warning)"
    elif [ "$rc" = "0" ]; then
        fail "T4: exit 0 but no 'LLM stage error' in stderr; got: $out"
    else
        fail "T4: LLM error should be fail-open (exit 0), got rc=$rc; output: $out"
    fi
}

run_t5() {
    require_cli "T5: text <50 chars → LLM tier skipped (no API call)" || return
    local rc out
    rc=0
    out=$(ANTHROPIC_API_KEY="test-invalid-key-for-unit-test" run_with_timeout 30 "$CLI" --stdin "testlabel" <<< "short text" 2>&1) || rc=$?
    # Short text skips LLM entirely; no API error should appear in stderr
    if [ "$rc" = "0" ] && ! echo "$out" | grep -qi "LLM stage"; then
        pass "T5: short text (<50 chars) → LLM tier skipped, exit 0"
    elif [ "$rc" = "0" ] && echo "$out" | grep -qi "LLM stage skipped"; then
        pass "T5: short text (<50 chars) → LLM skip warning, exit 0"
    else
        fail "T5: short text should exit 0 without LLM, got rc=$rc; output: $out"
    fi
}

run_t_prompt() {
    require_cli "T-prompt: buildLlmPrompt exports STANDING_INSTRUCTION + <item> envelope" || return
    if ! command -v node >/dev/null 2>&1; then
        skip "T-prompt: node missing"
        return
    fi
    local rc out
    rc=0
    out=$(cd "$AGENTS_DIR" && run_with_timeout 10 node -e \
        'const m = require("./bin/scan-offensive"); process.stdout.write(m.buildLlmPrompt("hello body", "test-label"));' 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "T-prompt: node invocation failed rc=$rc; out=$out"
        return
    fi
    # (a) standing instruction substring
    if ! grep -q "untrusted content scanned" <<< "$out"; then
        fail "T-prompt(a): output missing 'untrusted content scanned' from STANDING_INSTRUCTION"
        return
    fi
    # (b) <item ...> attributes — keyword-verdict="n/a", source="stdin", and </item> close
    if ! grep -q '<item ' <<< "$out"; then
        fail "T-prompt(b): output missing '<item '"
        return
    fi
    if ! grep -q 'keyword-verdict="n/a"' <<< "$out"; then
        fail "T-prompt(b): output missing keyword-verdict=\"n/a\""
        return
    fi
    if ! grep -q 'source="stdin"' <<< "$out"; then
        fail "T-prompt(b): output missing source=\"stdin\""
        return
    fi
    if ! grep -q '</item>' <<< "$out"; then
        fail "T-prompt(b): output missing '</item>'"
        return
    fi
    # (c) length comparison
    local prompt_len si_len
    prompt_len=$(printf '%s' "$out" | wc -c)
    si_len=$(cd "$AGENTS_DIR" && run_with_timeout 10 node -e \
        'const m = require("./bin/scan-offensive"); process.stdout.write(String(m.STANDING_INSTRUCTION.length));' 2>/dev/null)
    if [ -z "$si_len" ] || [ "$prompt_len" -le "$si_len" ]; then
        fail "T-prompt(c): prompt len ($prompt_len) not greater than STANDING_INSTRUCTION len ($si_len)"
        return
    fi
    pass "T-prompt: buildLlmPrompt has standing-instruction + envelope + correct envelope shape"
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t_prompt

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
