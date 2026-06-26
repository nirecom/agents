#!/usr/bin/env bash
# Tests: hooks/lib/subagent-detect.js, hooks/block-subagent-sentinels.js
# Tags: scope:issue-specific
# L2 integration tests for the subagent-sentinel block hook and its detect lib.
# Pre-implementation: hooks/lib/subagent-detect.js and hooks/block-subagent-sentinels.js
# do not exist yet — tests that exercise them are EXPECTED to FAIL until the
# implementation lands. The suite itself being runnable is the success criterion.
#
# L3 gap: hook registration ORDER (that block-subagent-sentinels.js fires before
# show-user-verified-context.js and confirm-checkpoint.js in the PreToolUse chain,
# so the ask dialog is suppressed for subagent-issued sentinels) is only verifiable
# in a real `claude -p` session where a subagent actually issues the Bash command
# and the ask dialog would otherwise materialize. These L2 tests verify the hook's
# decision:block / decision:approve output but cannot confirm end-to-end dialog
# suppression nor cross-hook ordering.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/block-subagent-sentinels.js"
DETECT_LIB="$AGENTS_DIR/hooks/lib/subagent-detect.js"
ERRORS=0
PASS_COUNT=0

# ---------------------------------------------------------------------------
# Portable timeout wrapper (macOS does not have timeout)
# ---------------------------------------------------------------------------
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Temp dir (Windows-compatible)
# ---------------------------------------------------------------------------
TMPDIR_ROOT="$(node -e "const os=require('os'),path=require('path'),fs=require('fs'),crypto=require('crypto');const d=path.join(os.tmpdir(),'subdetect-'+crypto.randomBytes(6).toString('hex'));fs.mkdirSync(d,{recursive:true});process.stdout.write(d);")"
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }

# run_hook <json> — pipe JSON to the block hook, return stdout
run_hook() {
    local json="$1"
    local input_file
    input_file="$(mktemp "$TMPDIR_ROOT/hook_input.XXXXXX")"
    printf '%s' "$json" > "$input_file"
    local result
    result=$(run_with_timeout node "$HOOK" < "$input_file" 2>/dev/null) || true
    rm -f "$input_file"
    printf '%s' "$result"
}

decision_of() {
    node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$1" 2>/dev/null || true
}

assert_decision() {
    local id="$1" desc="$2" json="$3" expected="$4"
    local result decision
    result=$(run_hook "$json")
    decision=$(decision_of "$result")
    if [ "$decision" = "$expected" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — expected ${expected}, got: ${result}"
    fi
}

# assert_predicate <id> <desc> <input-json-literal> <expected-bool>
# Calls isSubagentCall(input) directly via node -e against the detect lib.
assert_predicate() {
    local id="$1" desc="$2" input_expr="$3" expected="$4"
    local result
    result=$(run_with_timeout node -e "
        try {
            const { isSubagentCall } = require(process.argv[1]);
            const input = ${input_expr};
            process.stdout.write(String(isSubagentCall(input) === true));
        } catch (e) {
            process.stdout.write('ERR:' + e.message);
        }
    " -- "$DETECT_LIB" 2>/dev/null) || true
    if [ "$result" = "$expected" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — expected ${expected}, got: ${result}"
    fi
}

# ===========================================================================
# Predicate unit tests — isSubagentCall(input)
# ===========================================================================
echo ""
echo "=== subagent-detect predicate (isSubagentCall) ==="

assert_predicate "P1" "agent_id non-empty string → true" \
    '{ agent_id: "a1" }' "true"
assert_predicate "P2" "agent_id undefined → false (fail-safe)" \
    '{}' "false"
assert_predicate "P3" "agent_id null → false" \
    '{ agent_id: null }' "false"
assert_predicate "P4" 'agent_id "" (empty string) → false' \
    '{ agent_id: "" }' "false"
assert_predicate "P5" "agent_id non-string (number 123) → false" \
    '{ agent_id: 123 }' "false"
assert_predicate "P6" "input itself null → false (type guard)" \
    'null' "false"
assert_predicate "P7" "input undefined → false" \
    'undefined' "false"
assert_predicate "P8" 'agent_id whitespace-only "   " → true (length > 0)' \
    '{ agent_id: "   " }' "true"

# ===========================================================================
# block-subagent-sentinels.js PreToolUse decision tests
# ===========================================================================
echo ""
echo "=== block-subagent-sentinels.js PreToolUse ==="

# TC1: subagent + single sentinel → block
assert_decision "TC1" "subagent + single sentinel → block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: x>>\""},"agent_id":"a1","session_id":"s1"}' \
    "block"

# TC2: subagent + sentinel with && inside reason (C2 regression) → block
assert_decision "TC2" "subagent + sentinel with && in reason → block (naive split would miss)" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: a && b>>\""},"agent_id":"a1","session_id":"s1"}' \
    "block"

# TC3: subagent + sentinel && non-sentinel chain → block
assert_decision "TC3" "subagent + sentinel && non-sentinel chain → block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: x>>\" && rm /tmp/y"},"agent_id":"a1","session_id":"s1"}' \
    "block"

# TC4: subagent + non-sentinel Bash → approve
assert_decision "TC4" "subagent + non-sentinel Bash (git status) → approve" \
    '{"tool_name":"Bash","tool_input":{"command":"git status"},"agent_id":"a1","session_id":"s1"}' \
    "approve"

# TC5: subagent + sentinel-like substring in args (false-positive rejection) → approve
assert_decision "TC5" "subagent + sentinel-like substring in grep args → approve (chain-boundary regex excludes args)" \
    '{"tool_name":"Bash","tool_input":{"command":"grep '"'"'<<WORKFLOW_'"'"' file && wc -l"},"agent_id":"a1","session_id":"s1"}' \
    "approve"

# TC6: main conversation (no agent_id) + single sentinel → approve
assert_decision "TC6" "main (agent_id absent) + single sentinel → approve (orchestrator allowed)" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: x>>\""},"session_id":"s1"}' \
    "approve"

# TC7: main + sentinel with && in reason → approve
assert_decision "TC7" "main (agent_id absent) + sentinel with && in reason → approve" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: a && b>>\""},"session_id":"s1"}' \
    "approve"

# TC8: malformed stdin (non-JSON) → fail-open approve
echo ""
echo "--- TC8: malformed stdin (fail-open) ---"
tc8_input_file="$(mktemp "$TMPDIR_ROOT/tc8.XXXXXX")"
printf '%s' 'NOT VALID JSON {{{' > "$tc8_input_file"
tc8_result=$(run_with_timeout node "$HOOK" < "$tc8_input_file" 2>/dev/null) || true
rm -f "$tc8_input_file"
tc8_decision=$(decision_of "$tc8_result")
if [ "$tc8_decision" = "approve" ]; then
    pass "TC8. malformed stdin → approve (fail-open)"
else
    fail "TC8. malformed stdin — expected approve, got: ${tc8_result}"
fi

# TC9: tool_name Edit (not Bash) + agent_id + sentinel → approve (Bash-only)
assert_decision "TC9" "tool_name Edit + agent_id + sentinel → approve (Bash-only)" \
    '{"tool_name":"Edit","tool_input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: x>>\""},"agent_id":"a1","session_id":"s1"}' \
    "approve"

# TC10: empty command + agent_id → approve
assert_decision "TC10" "empty command + agent_id → approve" \
    '{"tool_name":"Bash","tool_input":{"command":""},"agent_id":"a1","session_id":"s1"}' \
    "approve"

# TC11: subagent + sentinel text inside variable assignment (not literal echo) → approve
assert_decision "TC11" "subagent + sentinel in var assignment → approve (no detector matches)" \
    '{"tool_name":"Bash","tool_input":{"command":"FOO=\"<<WORKFLOW_CONFIRM_INTENT: x>>\"; echo \"$FOO\""},"agent_id":"a1","session_id":"s1"}' \
    "approve"

# TC12: subagent + sentinel text inside a comment → approve
assert_decision "TC12" "subagent + sentinel in comment → approve (no detector fires)" \
    '{"tool_name":"Bash","tool_input":{"command":"git status # <<WORKFLOW_CONFIRM_INTENT: x>>"},"agent_id":"a1","session_id":"s1"}' \
    "approve"

# TC13: subagent with malicious agent_id value + literal sentinel → block (agent_id never evaluated)
assert_decision "TC13" "subagent + malicious agent_id value + sentinel → block (agent_id boolean-only)" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: x>>\""},"agent_id":"\"; rm /tmp/*;\"","session_id":"s1"}' \
    "block"

# ===========================================================================
# Results
# ===========================================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS_COUNT + ERRORS))
echo "${PASS_COUNT}/${TOTAL} tests passed, ${ERRORS} failed"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "${ERRORS} test(s) failed"
    exit 1
fi
