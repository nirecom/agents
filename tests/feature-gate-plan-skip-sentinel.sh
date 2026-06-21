#!/bin/bash
# Tests: hooks/gate-plan-skip-sentinel.js
# Tags: workflow, outline, planning, sentinel, hook, scope:common
# Tests for hooks/gate-plan-skip-sentinel.js (PreToolUse hook).
#
# Behavior contract:
#   When CONFIRM_OUTLINE=off, echo of <<WORKFLOW_OUTLINE_NOT_NEEDED: <reason>>>
#   is auto-approved via permissionDecision=allow. Same for CONFIRM_DETAIL/
#   DETAIL_NOT_NEEDED and CONFIRM_TESTS/WRITE_TESTS_NOT_NEEDED.
#   All other inputs pass through (empty JSON output → no decision).
#
# L3 gap: these tests invoke the hook via direct `node <hook>` calls (L2).
#   A live claude -p session would additionally verify:
#   (a) the hook is registered in settings.json and fires on real PreToolUse events;
#   (b) the sentinel echo in a real Bash tool invocation is actually allowed without
#       a prompt interrupt in the live Claude Code UI.
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

echo "=== T2: OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE=0 → pass-through (vocabulary narrowed: 0 no longer recognized) ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach>>"')
CONFIRM_OUTLINE=0 assert_passthrough \
    "T2. CONFIRM_OUTLINE=0 → pass-through (vocabulary narrowed)" "$INPUT"

echo "=== T3: OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE=on → pass-through (ask permissions) ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach>>"')
CONFIRM_OUTLINE=on assert_passthrough \
    "T3. CONFIRM_OUTLINE=on → pass-through" "$INPUT"

echo "=== T4: OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE unset → pass-through ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach>>"')
unset CONFIRM_OUTLINE 2>/dev/null || true
assert_passthrough \
    "T4. CONFIRM_OUTLINE unset → pass-through" "$INPUT"

echo "=== T4b: OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE=\"\" (empty string) → pass-through (fail-safe to ON) ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach>>"')
CONFIRM_OUTLINE="" assert_passthrough \
    "T4b. CONFIRM_OUTLINE=\"\" (empty) → pass-through (fail-safe to ON)" "$INPUT"

echo "=== T5: DETAIL_NOT_NEEDED with CONFIRM_DETAIL=off → allow ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: trivial change>>"')
CONFIRM_DETAIL=off assert_allow \
    "T5. DETAIL_NOT_NEEDED + CONFIRM_DETAIL=off → allow" "$INPUT"

echo "=== T6: DETAIL_NOT_NEEDED with CONFIRM_DETAIL=false → pass-through (vocabulary narrowed: false no longer recognized) ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: trivial change>>"')
CONFIRM_DETAIL=false assert_passthrough \
    "T6. CONFIRM_DETAIL=false → pass-through (vocabulary narrowed)" "$INPUT"

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

echo "=== T12: WRITE_TESTS_NOT_NEEDED with CONFIRM_TESTS=off → allow ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: docs-only change>>"')
CONFIRM_TESTS=off assert_allow \
    "T12. WRITE_TESTS_NOT_NEEDED + CONFIRM_TESTS=off → allow" "$INPUT"

echo "=== T13: WRITE_TESTS_NOT_NEEDED with CONFIRM_TESTS=on → pass-through ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: docs-only change>>"')
CONFIRM_TESTS=on assert_passthrough \
    "T13. CONFIRM_TESTS=on → pass-through" "$INPUT"

echo "=== T14: WRITE_TESTS_NOT_NEEDED with CONFIRM_TESTS=\"\" (empty string) → pass-through (fail-safe to ON) ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: docs-only change>>"')
# Isolate from parent .env (load-env.js treats "" as unset, so .env wins otherwise)
_T14_ENV=$(mktemp -d)
CONFIRM_TESTS="" AGENTS_CONFIG_DIR="$_T14_ENV" assert_passthrough \
    "T14. CONFIRM_TESTS=\"\" (empty) → pass-through (fail-safe to ON)" "$INPUT"
rmdir "$_T14_ENV" 2>/dev/null || true

echo "=== T14b: WRITE_TESTS_NOT_NEEDED with CONFIRM_TESTS unset → pass-through ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: docs-only change>>"')
# Isolate from parent .env so unset truly means unset
_T14B_ENV=$(mktemp -d)
unset CONFIRM_TESTS 2>/dev/null || true
AGENTS_CONFIG_DIR="$_T14B_ENV" assert_passthrough \
    "T14b. CONFIRM_TESTS unset → pass-through" "$INPUT"
rmdir "$_T14B_ENV" 2>/dev/null || true

echo "=== T15: WRITE_TESTS chained + CONFIRM_TESTS=off → pass-through ==="
INPUT=$(build_bash_input 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: x>>" && rm /tmp/x')
CONFIRM_TESTS=off assert_passthrough \
    "T15. chained command must NOT be auto-allowed" "$INPUT"

echo "=== T16: Malformed input (not valid JSON) → pass-through (fail-open) ==="
OUT=$(echo "not json {{{" | run_with_timeout node "$(to_node_path "$GATE_HOOK")" 2>/dev/null || true)
if [ -z "$OUT" ] || [ "$OUT" = "{}" ] || ! echo "$OUT" | grep -q '"permissionDecision"'; then
    pass "T16. malformed JSON → pass-through (fail-open)"
else
    fail "T16. expected pass-through on malformed stdin, got: $OUT"
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
