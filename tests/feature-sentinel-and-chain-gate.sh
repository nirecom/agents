#!/bin/bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-gate.js
# Tags: workflow, gate, hook, sentinel, bin
# Tests for:
#  Feature: Sentinel chain guard in hooks/workflow-gate.js
#    - Blocks `echo "<<WORKFLOW_*>>" && <non-sentinel>` chains that would
#      bypass workflow gating (the embedded sentinel echo silently drops in
#      workflow-mark.js because the whole-command shape is not a sentinel).
#    - Allows standalone sentinels and pure all-sentinel chains.
#    - Relies on the shared hooks/lib/sentinel-patterns.js library (also new).
#  Static regression: rules/git.md must enumerate all git write commands
#    that must NOT be chained with `&&` (per workflow-write hook coverage).
#
# Test-first: the guard + sentinel-patterns lib + rules/git.md expansion do
# not exist yet. Cases marked **block** in the table are expected to FAIL
# until Commits 1-2 of the implementation land. SG-STATIC-1 likewise FAILS
# until rules/git.md is expanded.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/hooks/workflow-gate.js"
RULES_GIT_MD="$DOTFILES_DIR/rules/git.md"
ERRORS=0
FAILED_IDS=()
PASSED_IDS=()

fail() {
    echo "FAIL: $1"
    ERRORS=$((ERRORS + 1))
    FAILED_IDS+=("$1")
}
pass() {
    echo "PASS: $1"
    PASSED_IDS+=("$1")
}

# Portable timeout wrapper (macOS has no `timeout` by default)
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_gate() {
    local json="$1"
    echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$GATE_HOOK" 2>/dev/null
}

# Build a PreToolUse Bash hook input. The sentinel chain guard is purely
# structural — it does not consult workflow state — so any dummy session id
# suffices. We do NOT pre-populate $WORKFLOW_DIR for these tests.
build_gate_input() {
    local cmd="$1" sid="${2:-sg-session}"
    # JSON-escape backslash and double-quote.
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' \
        "$esc" "$sid"
}

# Assert that the gate APPROVES the given command (decision != "block").
expect_approve() {
    local id="$1" cmd="$2"
    local out
    out=$(run_gate "$(build_gate_input "$cmd" "$id")")
    if echo "$out" | grep -q '"block"'; then
        fail "$id — expected approve, got block: $out"
    else
        pass "$id"
    fi
}

# Assert that the gate BLOCKS the given command.
expect_block() {
    local id="$1" cmd="$2"
    local out
    out=$(run_gate "$(build_gate_input "$cmd" "$id")")
    if echo "$out" | grep -q '"block"'; then
        pass "$id"
    else
        fail "$id — expected block, got: $out"
    fi
}

# ===========================================================================
# SG-1: Standalone sentinels and all-sentinel chains → approve
# ===========================================================================

echo ""
echo "=== SG-1: standalone / all-sentinel forms (approve) ==="

expect_approve "SG-1a" 'echo "<<WORKFLOW_USER_VERIFIED: reason>>"'
expect_approve "SG-1b" 'echo "<<WORKFLOW_USER_VERIFIED: SG-1b approve test>>" && echo "<<WORKFLOW_MARK_STEP_docs_complete>>"'

# ===========================================================================
# SG-1c / SG-2: reason text contains `&&` — naive split would yield >2
# fragments and break all-sentinel detection
# ===========================================================================

echo ""
echo "=== SG-1c / SG-2: reason text contains '&&' ==="

expect_block   "SG-1c" 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: a && b>>" && echo "<<WORKFLOW_MARK_STEP_research_complete>>"'
expect_block   "SG-2a" 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: a && b>>" && rm /tmp/x'
expect_approve "SG-2b" 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: a && b>>"'

# ===========================================================================
# SG-3: Non-sentinel command shapes → guard must not trip (approve)
# ===========================================================================

echo ""
echo "=== SG-3: non-sentinel forms (approve) ==="

# Prefix text before `<<` → not the canonical sentinel echo form.
expect_approve "SG-3a" 'echo "log: <<WORKFLOW_TRACE>>" && ls'
# No `<<WORKFLOW_` substring at all → guard must short-circuit.
expect_approve "SG-3b" 'git status && ls'
# Diagnostic grep — has `<<WORKFLOW_` substring but no `echo ... <<...>>` form.
expect_approve "SG-3c" "grep '<<WORKFLOW_' file && wc -l file"
# Single-quoted USER_VERIFIED → not a recognized sentinel echo form (only SQ
# MARK_STEP is accepted); whole-command isSentinel=false; chain-boundary SQ
# regex matches only MARK_STEP. Approve.
# Negative fixture: SQ form is intentionally unrecognized
expect_approve "SG-3d" "echo '<<WORKFLOW_USER_VERIFIED>>' && rm /tmp/x"

# ===========================================================================
# SG-4: Sentinel echo + non-sentinel chain → block (this is the bug)
# ===========================================================================

echo ""
echo "=== SG-4: sentinel + non-sentinel chain (block) ==="

expect_block "SG-4a" 'echo "<<WORKFLOW_USER_VERIFIED: SG-4a chain block>>" && rm -rf /tmp/foo'
expect_block "SG-4b" 'rm /tmp/foo && echo "<<WORKFLOW_USER_VERIFIED: SG-4b chain block>>"'
# SQ MARK_STEP IS recognized by both isSentinel and the chain-boundary SQ regex.
expect_block "SG-4c" "echo '<<WORKFLOW_MARK_STEP_docs_complete>>' && rm /tmp/x"
# DQ MARK_STEP with lowercase suffix — regex character class [A-Za-z_]+ must
# accept lowercase + underscore.
expect_block "SG-4d" 'echo "<<WORKFLOW_MARK_STEP_docs_complete>>" && rm /tmp/x'
# DQ RESET_FROM with lowercase suffix.
expect_block "SG-4e" 'echo "<<WORKFLOW_RESET_FROM_research>>" && rm /tmp/x'

# ===========================================================================
# SG-STATIC-1: rules/git.md states the chain prohibition
# ===========================================================================
# Rationale: the hook is the source of truth (it hard-stops chained writes),
# so the doc only needs to state the rule — no command enumeration required.

echo ""
echo "=== SG-STATIC-1: rules/git.md states the chain prohibition ==="

if [ ! -f "$RULES_GIT_MD" ]; then
    fail "SG-STATIC-1 — rules/git.md not found at $RULES_GIT_MD"
elif grep -qE 'separate sequential Bash calls' "$RULES_GIT_MD" \
     && grep -qE 'do NOT chain them with `&&`' "$RULES_GIT_MD"; then
    pass "SG-STATIC-1"
else
    fail "SG-STATIC-1 — rules/git.md must state the separate-calls / no-&&-chain rule"
fi

# ===========================================================================
# Results
# ===========================================================================

echo ""
echo "=== Results ==="
echo "PASSED: ${#PASSED_IDS[@]}"
echo "FAILED: ${#FAILED_IDS[@]}"
if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "Failed test IDs:"
    for id in "${FAILED_IDS[@]}"; do
        echo "  - $id"
    done
fi
echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "$ERRORS assertion(s) failed (expected pre-fix for sentinel chain guard + rules/git.md expansion)."
    exit 1
fi
