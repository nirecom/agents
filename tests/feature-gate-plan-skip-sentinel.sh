#!/bin/bash
# Tests: hooks/gate-plan-skip-sentinel.js
# Tags: workflow, outline, planning, sentinel, hook
# Tests for hooks/gate-plan-skip-sentinel.js (PreToolUse hook).
#
# Behavior contract:
#   When CONFIRM_OUTLINE=off (or other OFF literal), echo of
#   <<WORKFLOW_OUTLINE_NOT_NEEDED: <reason>>> is auto-approved via
#   permissionDecision=allow. Same for CONFIRM_DETAIL/DETAIL_NOT_NEEDED.
#   All other inputs pass through (empty JSON output → no decision).
#
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/gate-plan-skip-sentinel.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
    else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

to_node_path() {
    cygpath -m "$1" 2>/dev/null || echo "$1"
}

run_gate() {
    local input="$1"
    local hook_path
    hook_path=$(to_node_path "$GATE_HOOK")
    echo "$input" | run_with_timeout node "$hook_path" 2>/dev/null || true
}

# Convenience: build input JSON with a Bash command
build_bash_input() {
    local cmd="$1"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$esc"
}

assert_allow() {
    local desc="$1" input="$2"
    local out
    out=$(run_gate "$input")
    if echo "$out" | grep -q '"permissionDecision":"allow"'; then
        pass "$desc"
    else
        fail "$desc (expected permissionDecision=allow, got: $out)"
    fi
}

# A pass-through is empty JSON `{}` OR has no permissionDecision key.
assert_passthrough() {
    local desc="$1" input="$2"
    local out
    out=$(run_gate "$input")
    if [ -z "$out" ] || [ "$out" = "{}" ] || ! echo "$out" | grep -q '"permissionDecision"'; then
        pass "$desc"
    else
        fail "$desc (expected pass-through, got: $out)"
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo "=== T1: OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE=off → allow ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: single approach>>"')
CONFIRM_OUTLINE=off CONFIRM_DETAIL=on assert_allow \
    "T1. OUTLINE_NOT_NEEDED + CONFIRM_OUTLINE=off → allow" "$INPUT"

echo "=== T2: OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE=0 → allow (case literal) ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach>>"')
CONFIRM_OUTLINE=0 assert_allow \
    "T2. CONFIRM_OUTLINE=0 → allow" "$INPUT"

echo "=== T3: OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE=on → pass-through (ask permissions) ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach>>"')
CONFIRM_OUTLINE=on assert_passthrough \
    "T3. CONFIRM_OUTLINE=on → pass-through" "$INPUT"

echo "=== T4: OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE unset → pass-through ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach>>"')
unset CONFIRM_OUTLINE 2>/dev/null || true
assert_passthrough \
    "T4. CONFIRM_OUTLINE unset → pass-through" "$INPUT"

echo "=== T5: DETAIL_NOT_NEEDED with CONFIRM_DETAIL=off → allow ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: trivial change>>"')
CONFIRM_DETAIL=off assert_allow \
    "T5. DETAIL_NOT_NEEDED + CONFIRM_DETAIL=off → allow" "$INPUT"

echo "=== T6: DETAIL_NOT_NEEDED with CONFIRM_DETAIL=false → allow ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: trivial change>>"')
CONFIRM_DETAIL=false assert_allow \
    "T6. CONFIRM_DETAIL=false → allow" "$INPUT"

echo "=== T7: DETAIL_NOT_NEEDED with CONFIRM_DETAIL=on → pass-through ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: trivial change>>"')
CONFIRM_DETAIL=on assert_passthrough \
    "T7. CONFIRM_DETAIL=on → pass-through" "$INPUT"

echo "=== T8: DETAIL_NOT_NEEDED with CONFIRM_DETAIL=on → pass-through ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: trivial change>>"')
CONFIRM_DETAIL=on assert_passthrough \
    "T8. CONFIRM_DETAIL=on (not off) → pass-through" "$INPUT"

echo "=== T9: Non-sentinel Bash command → pass-through even with CONFIRM_OUTLINE=off ==="
INPUT=$(build_bash_input 'ls -la')
CONFIRM_OUTLINE=off CONFIRM_DETAIL=off assert_passthrough \
    "T9. unrelated Bash command → pass-through" "$INPUT"

echo "=== T10: Non-Bash tool → pass-through ==="
INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/foo.txt"}}'
CONFIRM_OUTLINE=off assert_passthrough \
    "T10. non-Bash tool → pass-through" "$INPUT"

echo "=== T11: OUTLINE sentinel chained with && → pass-through (must not auto-allow chains) ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: x>>" && rm /tmp/x')
CONFIRM_OUTLINE=off assert_passthrough \
    "T11. chained command must NOT be auto-allowed" "$INPUT"

echo "=== T12: Malformed input (not valid JSON) → pass-through (fail-open) ==="
OUT=$(echo "not json {{{" | run_with_timeout node "$(to_node_path "$GATE_HOOK")" 2>/dev/null || true)
if [ -z "$OUT" ] || [ "$OUT" = "{}" ] || ! echo "$OUT" | grep -q '"permissionDecision"'; then
    pass "T12. malformed JSON → pass-through (fail-open)"
else
    fail "T12. expected pass-through on malformed stdin, got: $OUT"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
