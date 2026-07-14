#!/bin/bash
# Tests: bin/workflow/record-complexity-and-skip
# Tags: L2, workflow, speculative-skip, scope:issue-specific
# Security: N/A -- pure state-write logic; no external untrusted input
# L3 gap (what this test does NOT catch):
# - Whether clarify-intent SKILL.md and workflow-init SKILL.md correctly invoke
#   record-complexity-and-skip at the right step with correct verdict/signals
# - End-to-end: real claude -p session running complexity evaluation + skip judgment
# Closest-to-action mitigation: wiring gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Tests the stdout purity contract of bin/workflow/record-complexity-and-skip:
# stdout MUST be exactly 'auto' or 'judgment' -- never RECORDED_* lines from sub-CLIs.

set -u

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available"
    exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RCS_SCRIPT="$AGENTS_DIR/bin/workflow/record-complexity-and-skip"
STATEIO="$AGENTS_DIR/hooks/lib/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"
READ_CE="$AGENTS_DIR/bin/workflow/read-complexity-evaluation"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e "alarm $secs; exec @ARGV" -- "$@"; fi
}

# Guard: if script doesn't exist yet, record RED failures for all cases
require_rcs() {
    if [ -x "$RCS_SCRIPT" ] || [ -f "$RCS_SCRIPT" ]; then return 0; fi
    fail "$1: record-complexity-and-skip not found at $RCS_SCRIPT (RED until /write-code)"
    return 1
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"
mkdir -p "$WORKFLOW_DIR"
WORKFLOW_DIR_N="$(cygpath -m "$WORKFLOW_DIR" 2>/dev/null || echo "$WORKFLOW_DIR")"

# Helper: read complexity evaluation for a session
read_ce_verdict() {
    local sid="$1"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout 10 node "$READ_CE" --session "$sid" 2>/dev/null | grep -oE 'level=[^ ]+' | head -1 || true
}

# Helper: read skip judgment for a session+target
read_skip_judgment() {
    local sid="$1" target="$2"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout 10 node -e "
const io = require('$STATEIO_N');
try {
    const s = io.readState('$sid');
    const sj = s && s.skip_judgment && s.skip_judgment['$target'];
    console.log(sj ? JSON.stringify(sj) : 'null');
} catch(e) { console.log('null'); }
" 2>/dev/null || echo "null"
}

echo "=== RCS-1: auto path stdout purity (verdict=low, signals='') ==="
if require_rcs "RCS-1"; then
    SID="rcs1-$$"
    OUT=$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --verdict low --signals "" --target outline 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "auto" ]; then
        pass "RCS-1: stdout === 'auto' for 0-signal sonnet"
    else
        fail "RCS-1: expected 'auto', got rc=$RC out='$OUT'"
    fi
fi

echo "=== RCS-2: judgment path stdout purity (verdict=high, signals=S1-multi-file) ==="
if require_rcs "RCS-2"; then
    SID="rcs2-$$"
    OUT=$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --verdict high --signals "S1-multi-file" --target outline 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "judgment" ]; then
        pass "RCS-2: stdout === 'judgment' for high verdict"
    else
        fail "RCS-2: expected 'judgment', got rc=$RC out='$OUT'"
    fi
fi

echo "=== RCS-3: no RECORDED_* lines in stdout (max 1 line) ==="
if require_rcs "RCS-3"; then
    SID="rcs3-$$"
    OUT=$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --verdict low --signals "" --target outline 2>/dev/null)
    RC=$?
    LINE_COUNT=$(printf '%s' "$OUT" | wc -l | tr -d ' ')
    # wc -l counts newlines, so "auto" (no trailing newline) gives 0; "auto\n" gives 1.
    # Either 0 or 1 is acceptable; 2+ means RECORDED_* leaked.
    if [ "$RC" -eq 0 ] && [ "$LINE_COUNT" -le 1 ] && ! printf '%s' "$OUT" | grep -q 'RECORDED'; then
        pass "RCS-3: stdout has <=1 line, no RECORDED_* contamination"
    else
        fail "RCS-3: stdout lines=$LINE_COUNT or contains RECORDED_*; out='$OUT'"
    fi
fi

echo "=== RCS-4: auto path writes skip-judgment record ==="
if require_rcs "RCS-4"; then
    SID="rcs4-$$"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --verdict low --signals "" --target outline >/dev/null 2>&1
    SJ=$(read_skip_judgment "$SID" "outline")
    if printf '%s' "$SJ" | grep -q '"all_conditions_met":true\|"all_conditions_met": true'; then
        pass "RCS-4: auto path wrote skip-judgment with all_conditions_met=true"
    else
        fail "RCS-4: skip-judgment not recorded or all_conditions_met not true; got: $SJ"
    fi
fi

echo "=== RCS-5: judgment path does NOT write skip-judgment ==="
if require_rcs "RCS-5"; then
    SID="rcs5-$$"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --verdict high --signals "S1-multi-file" --target outline >/dev/null 2>&1
    SJ=$(read_skip_judgment "$SID" "outline")
    if [ "$SJ" = "null" ]; then
        pass "RCS-5: judgment path correctly does not write skip-judgment"
    else
        fail "RCS-5: skip-judgment was unexpectedly written on judgment path; got: $SJ"
    fi
fi

echo "=== RCS-6: complexity_evaluation always recorded (auto path) ==="
if require_rcs "RCS-6a"; then
    SID="rcs6a-$$"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --verdict low --signals "" --target outline >/dev/null 2>&1
    CE=$(read_ce_verdict "$SID")
    if [ -n "$CE" ]; then
        pass "RCS-6a: complexity_evaluation recorded on auto path (verdict=$CE)"
    else
        fail "RCS-6a: complexity_evaluation NOT recorded on auto path"
    fi
fi

echo "=== RCS-6b: complexity_evaluation always recorded (judgment path) ==="
if require_rcs "RCS-6b"; then
    SID="rcs6b-$$"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --verdict high --signals "S1-multi-file" --target outline >/dev/null 2>&1
    CE=$(read_ce_verdict "$SID")
    if [ -n "$CE" ]; then
        pass "RCS-6b: complexity_evaluation recorded on judgment path (verdict=$CE)"
    else
        fail "RCS-6b: complexity_evaluation NOT recorded on judgment path"
    fi
fi

echo "=== RCS-7: --target detail auto path records sd_c3 in skip-judgment ==="
if require_rcs "RCS-7"; then
    SID="rcs7-$$"
    OUT=$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --verdict low --signals "" --target detail 2>/dev/null)
    RC=$?
    SJ=$(read_skip_judgment "$SID" "detail")
    if [ "$RC" -eq 0 ] && [ "$OUT" = "auto" ] && printf '%s' "$SJ" | grep -q 'sd_c3'; then
        pass "RCS-7: --target detail auto path -> stdout=auto, skip-judgment has sd_c3"
    else
        fail "RCS-7: rc=$RC out='$OUT' sj=$SJ (expected auto stdout + sd_c3 in judgment)"
    fi
fi

echo "=== RCS-8: missing AGENTS_CONFIG_DIR -> non-zero exit ==="
if require_rcs "RCS-8"; then
    SID="rcs8-$$"
    SAVED_ACD="$AGENTS_CONFIG_DIR"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" AGENTS_CONFIG_DIR="" \
        run_with_timeout 5 bash "$RCS_SCRIPT" --session "$SID" --verdict low --signals "" --target outline >/dev/null 2>/dev/null
    RC=$?
    # restore
    export AGENTS_CONFIG_DIR="$SAVED_ACD"
    if [ "$RC" -ne 0 ]; then
        pass "RCS-8: missing AGENTS_CONFIG_DIR -> non-zero exit ($RC)"
    else
        fail "RCS-8: expected non-zero exit with missing AGENTS_CONFIG_DIR, got 0"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
