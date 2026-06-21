#!/bin/bash
# tests/feature-1010-scan-offensive-skill-mode.sh
# Tests: bin/scan-offensive --skill-mode / --source-json / --print-standing-instruction
# Tags: scan, offensive, skill-mode, jsonl, source-json, scope:issue-specific
# RED for issue #1010 — skill-mode emits JSONL manifest items rather than process exit-codes.
#
# L3 gap (what this test does NOT catch):
# - real Anthropic API absence verification across all network paths (only stubs https/env-var read)
# - real CC inline-evaluation pass of the standing instruction text
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$AGENTS_DIR/bin/scan-offensive"

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

# Returns 0 if `jq` is available, else marks the test SKIPPED.
require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        skip "$1 (jq not available)"
        return 1
    fi
    return 0
}

SRC_JSON_VALID='{"kind":"issue-body","repo":"o/r","issue":42,"comment_id":null,"url":"https://github.com/o/r/issues/42"}'

run_t1() {
    require_cli "T1: --skill-mode clean stdin → exit 0, single JSONL item, verdict=clean" || return
    require_jq "T1: --skill-mode clean stdin (jq missing)" || return
    local rc out
    rc=0
    out=$(echo "this is a perfectly clean sentence" \
        | SCAN_OFFENSIVE_SOURCE_JSON="$SRC_JSON_VALID" \
          run_with_timeout 30 "$CLI" --stdin "t1-skill-clean" --skill-mode 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "T1: expected rc=0, got rc=$rc; out=$out"
        return
    fi
    local nlines
    nlines=$(printf '%s\n' "$out" | grep -c '.')
    if [ "$nlines" -ne 1 ]; then
        fail "T1: expected exactly 1 JSONL line, got $nlines"
        return
    fi
    if ! printf '%s' "$out" | jq -e '.type=="item" and .schema=="scan-offensive/skill-manifest/v1" and .keyword_verdict=="clean"' >/dev/null 2>&1; then
        fail "T1: JSONL did not satisfy type/schema/keyword_verdict assertion; out=$out"
        return
    fi
    pass "T1: --skill-mode clean stdin → exit 0, single JSONL item, verdict=clean"
}

run_t2() {
    require_cli "T2: --skill-mode hard-keyword → exit 0, verdict=hard, hits[0].tier=hard" || return
    require_jq "T2: --skill-mode hard-keyword (jq missing)" || return
    local rc out tmp_bl
    tmp_bl=$(mktemp)
    printf '%s\n' "__skillmode_hard_kw__" > "$tmp_bl"
    rc=0
    out=$(echo "this body contains __skillmode_hard_kw__ here" \
        | SCAN_OFFENSIVE_SOURCE_JSON="$SRC_JSON_VALID" \
          SCAN_OFFENSIVE_BLOCKLIST="$tmp_bl" \
          run_with_timeout 30 "$CLI" --stdin "t2-skill-hard" --skill-mode 2>/dev/null) || rc=$?
    rm -f "$tmp_bl"
    if [ "$rc" -ne 0 ]; then
        fail "T2: --skill-mode keyword-hit must still exit 0; got rc=$rc"
        return
    fi
    if ! printf '%s' "$out" | jq -e '.keyword_verdict=="hard" and (.keyword_hits|length>=1) and .keyword_hits[0].tier=="hard"' >/dev/null 2>&1; then
        fail "T2: JSONL did not match hard-verdict/hits assertion; out=$out"
        return
    fi
    pass "T2: --skill-mode hard-keyword → exit 0, verdict=hard, hits[0].tier=hard"
}

run_t3() {
    require_cli "T3: --skill-mode does not invoke callAnthropic and does not read ANTHROPIC_API_KEY" || return
    # Stub https.request and Object.defineProperty on process.env via NODE_OPTIONS --require.
    local stub_dir stub_file rc stderr_file
    stub_dir=$(mktemp -d)
    stub_file="$stub_dir/stub.js"
    cat > "$stub_file" <<'EOF'
"use strict";
const https = require("https");
const origReq = https.request;
https.request = function () {
  process.stderr.write("STUB_HTTPS_INVOKED\n");
  return origReq.apply(this, arguments);
};
const origGetter = Object.getOwnPropertyDescriptor(process, "env");
// Wrap process.env in a Proxy to detect reads of ANTHROPIC_API_KEY.
const realEnv = process.env;
const wrapped = new Proxy(realEnv, {
  get(t, k) {
    if (k === "ANTHROPIC_API_KEY") {
      process.stderr.write("STUB_ENV_READ_ANTHROPIC_API_KEY\n");
    }
    return t[k];
  },
});
Object.defineProperty(process, "env", { value: wrapped, configurable: true });
EOF
    stderr_file=$(mktemp)
    rc=0
    echo "a clean sentence with sufficient length to potentially trigger an llm tier path here" \
        | NODE_OPTIONS="--require $stub_file" \
          ANTHROPIC_API_KEY="dummy-key-for-test" \
          SCAN_OFFENSIVE_SOURCE_JSON="$SRC_JSON_VALID" \
          run_with_timeout 30 "$CLI" --stdin "t3-skill-no-llm" --skill-mode >/dev/null 2>"$stderr_file" || rc=$?
    local stderr_content
    stderr_content=$(cat "$stderr_file" 2>/dev/null || echo "")
    rm -rf "$stub_dir" "$stderr_file"
    if grep -q "STUB_HTTPS_INVOKED" <<< "$stderr_content"; then
        fail "T3: skill-mode invoked https.request (callAnthropic should not run); stderr=$stderr_content"
        return
    fi
    if grep -q "STUB_ENV_READ_ANTHROPIC_API_KEY" <<< "$stderr_content"; then
        fail "T3: skill-mode read ANTHROPIC_API_KEY; stderr=$stderr_content"
        return
    fi
    pass "T3: --skill-mode does not call https and does not read ANTHROPIC_API_KEY"
}

run_t4() {
    require_cli "T4: SCAN_OFFENSIVE_SOURCE_JSON populates manifest source fields" || return
    require_jq "T4: source-json (jq missing)" || return
    local rc out
    rc=0
    out=$(echo "clean body" \
        | SCAN_OFFENSIVE_SOURCE_JSON="$SRC_JSON_VALID" \
          run_with_timeout 30 "$CLI" --stdin "t4-source" --skill-mode 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "T4: expected rc=0, got rc=$rc"
        return
    fi
    if ! printf '%s' "$out" | jq -e '.source.issue==42 and .source.kind=="issue-body"' >/dev/null 2>&1; then
        fail "T4: manifest source.issue/kind mismatch; out=$out"
        return
    fi
    pass "T4: SCAN_OFFENSIVE_SOURCE_JSON populates manifest source fields"
}

run_t5() {
    require_cli "T5: stdout is parseable JSONL; no '#' comment lines" || return
    require_jq "T5: stdout JSONL (jq missing)" || return
    local rc out
    rc=0
    out=$(echo "clean body for parse test" \
        | SCAN_OFFENSIVE_SOURCE_JSON="$SRC_JSON_VALID" \
          run_with_timeout 30 "$CLI" --stdin "t5-jsonl" --skill-mode 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "T5: expected rc=0, got rc=$rc"
        return
    fi
    if printf '%s\n' "$out" | grep -Eq '^[[:space:]]*#'; then
        fail "T5: stdout contains '#' comment line; out=$out"
        return
    fi
    # Every non-blank line must parse as JSON.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
            fail "T5: line is not JSON: $line"
            return
        fi
    done <<< "$out"
    pass "T5: stdout is parseable JSONL; no '#' comment lines"
}

run_t6() {
    require_cli "T6: invalid --source-json JSON → exit 3 with 'invalid JSON'" || return
    local rc stderr_file stderr_content
    stderr_file=$(mktemp)
    rc=0
    echo "clean body" \
        | SCAN_OFFENSIVE_SOURCE_JSON='{not json}' \
          run_with_timeout 30 "$CLI" --stdin "t6-bad-json" --skill-mode >/dev/null 2>"$stderr_file" || rc=$?
    stderr_content=$(cat "$stderr_file" 2>/dev/null || echo "")
    rm -f "$stderr_file"
    if [ "$rc" -ne 3 ]; then
        fail "T6: expected rc=3 for invalid JSON, got rc=$rc; stderr=$stderr_content"
        return
    fi
    if ! grep -qi "invalid json" <<< "$stderr_content"; then
        fail "T6: stderr missing 'invalid JSON' marker; stderr=$stderr_content"
        return
    fi
    pass "T6: invalid --source-json JSON → exit 3 with 'invalid JSON'"
}

run_t7() {
    require_cli "T7: source-json missing required keys → exit 3 'missing required key'" || return
    local rc stderr_file stderr_content
    stderr_file=$(mktemp)
    rc=0
    echo "clean body" \
        | SCAN_OFFENSIVE_SOURCE_JSON='{"kind":"issue-body"}' \
          run_with_timeout 30 "$CLI" --stdin "t7-missing-keys" --skill-mode >/dev/null 2>"$stderr_file" || rc=$?
    stderr_content=$(cat "$stderr_file" 2>/dev/null || echo "")
    rm -f "$stderr_file"
    if [ "$rc" -ne 3 ]; then
        fail "T7: expected rc=3 for missing keys, got rc=$rc; stderr=$stderr_content"
        return
    fi
    if ! grep -qi "missing required key" <<< "$stderr_content"; then
        fail "T7: stderr missing 'missing required key' marker; stderr=$stderr_content"
        return
    fi
    pass "T7: source-json missing required keys → exit 3 'missing required key'"
}

run_t8() {
    require_cli "T8: source-json invalid kind → exit 3, stderr mentions 'kind'" || return
    local rc stderr_file stderr_content
    stderr_file=$(mktemp)
    rc=0
    echo "clean body" \
        | SCAN_OFFENSIVE_SOURCE_JSON='{"kind":"bogus","repo":null,"issue":null,"comment_id":null,"url":null}' \
          run_with_timeout 30 "$CLI" --stdin "t8-bad-kind" --skill-mode >/dev/null 2>"$stderr_file" || rc=$?
    stderr_content=$(cat "$stderr_file" 2>/dev/null || echo "")
    rm -f "$stderr_file"
    if [ "$rc" -ne 3 ]; then
        fail "T8: expected rc=3 for bogus kind, got rc=$rc; stderr=$stderr_content"
        return
    fi
    if ! grep -qi "kind" <<< "$stderr_content"; then
        fail "T8: stderr does not mention 'kind'; stderr=$stderr_content"
        return
    fi
    pass "T8: source-json invalid kind → exit 3 mentions 'kind'"
}

run_t9() {
    require_cli "T9: --source-json flag overrides SCAN_OFFENSIVE_SOURCE_JSON env var" || return
    require_jq "T9: flag-vs-env precedence (jq missing)" || return
    local rc out
    local env_json flag_json
    env_json='{"kind":"issue-body","repo":"o/r","issue":11,"comment_id":null,"url":"https://github.com/o/r/issues/11"}'
    flag_json='{"kind":"issue-body","repo":"o/r","issue":22,"comment_id":null,"url":"https://github.com/o/r/issues/22"}'
    rc=0
    out=$(echo "clean body" \
        | SCAN_OFFENSIVE_SOURCE_JSON="$env_json" \
          run_with_timeout 30 "$CLI" --stdin "t9-precedence" --skill-mode --source-json "$flag_json" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "T9: expected rc=0, got rc=$rc; out=$out"
        return
    fi
    if ! printf '%s' "$out" | jq -e '.source.issue==22' >/dev/null 2>&1; then
        fail "T9: flag value did not win; expected issue=22; out=$out"
        return
    fi
    pass "T9: --source-json flag overrides env var"
}

run_t10() {
    require_cli "T10: --print-standing-instruction exit 0; non-empty; stable" || return
    local rc1 rc2 out1 out2
    rc1=0; rc2=0
    out1=$(run_with_timeout 10 "$CLI" --print-standing-instruction 2>/dev/null) || rc1=$?
    out2=$(run_with_timeout 10 "$CLI" --print-standing-instruction 2>/dev/null) || rc2=$?
    if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
        fail "T10: expected rc=0 both runs; rc1=$rc1 rc2=$rc2"
        return
    fi
    if [ -z "$out1" ]; then
        fail "T10: stdout empty"
        return
    fi
    if ! grep -q "untrusted content" <<< "$out1"; then
        fail "T10: stdout missing 'untrusted content' substring"
        return
    fi
    if [ "$out1" != "$out2" ]; then
        fail "T10: --print-standing-instruction output not byte-identical across runs"
        return
    fi
    pass "T10: --print-standing-instruction exit 0; non-empty; stable"
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

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
