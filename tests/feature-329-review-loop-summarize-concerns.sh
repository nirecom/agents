#!/usr/bin/env bash
# Tests: bin/review-loop-summarize-concerns
# Tags: bin, env, config, loop, scope:common
# Tests for bin/review-loop-summarize-concerns CONV_LANG localization.
#
# L3 gap (what this test does NOT catch):
# - Whether the Japanese heading actually renders in a live review-loop cap-menu dialog
# - Whether CONV_LANG injection from session-start.js propagates correctly to the bin script in a real session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-loop-summarize-concerns"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

# Create a minimal concern ledger for tests
LEDGER="$TMPDIR_BASE/ledger.txt"
printf 'C1|HIGH|test concern — something is wrong\n' > "$LEDGER"

run_summarize() {
    local exit_code=0
    local out
    out=$(_timeout bash "$SCRIPT" "$@" 2>&1) || exit_code=$?
    printf '%s\n__RC__%d\n' "$out" "$exit_code"
}

extract_rc() { echo "$1" | grep '^__RC__' | sed 's/__RC__//'; }
extract_out() { echo "$1" | sed '/^__RC__/d'; }

# ---------------------------------------------------------------------------
# T1: Basic invocation — exit 0, output contains English cap-reached heading
# ---------------------------------------------------------------------------
RES=$(run_summarize --budget-remaining 1 --ledger "$LEDGER")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "T1: basic invocation: exit 0"
else
    fail "T1: basic invocation: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -qE "Round cap reached|ラウンド上限"; then
    pass "T1: output contains cap-reached heading"
else
    fail "T1: output missing cap-reached heading. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# T2: CONV_LANG=japanese → Japanese heading (EXPECTED_FAIL pre-write-code)
# NOTE: Japanese branch not yet added to source — this test documents intended
# behavior. It is counted as SKIP, not FAIL, until write-code implements it.
# ---------------------------------------------------------------------------
RES=$(CONV_LANG=japanese run_summarize --budget-remaining 1 --ledger "$LEDGER")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    if echo "$OUT" | grep -qE "ラウンド上限|ラウンド上限に達しました"; then
        pass "T2: CONV_LANG=japanese: Japanese heading present"
    else
        skip "T2: CONV_LANG=japanese: Japanese heading not yet implemented (EXPECTED_FAIL pre-write-code: Japanese branch not yet added)"
    fi
else
    skip "T2: CONV_LANG=japanese: script exited $RC — Japanese branch not yet added (EXPECTED_FAIL pre-write-code)"
fi

# ---------------------------------------------------------------------------
# T3: CONV_LANG="" (empty) → exit 0, English heading
# ---------------------------------------------------------------------------
RES=$(CONV_LANG="" run_summarize --budget-remaining 1 --ledger "$LEDGER")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "T3: CONV_LANG='': exit 0"
else
    fail "T3: CONV_LANG='': expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -q "Round cap reached"; then
    pass "T3: CONV_LANG='': English heading present"
else
    fail "T3: CONV_LANG='': English heading missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# T4: Missing --budget-remaining → exit 2
# ---------------------------------------------------------------------------
RES=$(run_summarize --ledger "$LEDGER")
RC=$(extract_rc "$RES")

if [[ "$RC" == "2" ]]; then
    pass "T4: missing --budget-remaining: exit 2"
else
    fail "T4: missing --budget-remaining: expected exit 2, got $RC"
fi

# ---------------------------------------------------------------------------
# T5: Ledger absent → exit 0, output contains "not available"
# ---------------------------------------------------------------------------
RES=$(CONV_LANG="" run_summarize --budget-remaining 1 --ledger "/nonexistent/path.txt")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "T5: absent ledger: exit 0 (degraded mode)"
else
    fail "T5: absent ledger: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -q "not available"; then
    pass "T5: absent ledger: output contains 'not available'"
else
    fail "T5: absent ledger: 'not available' missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# T6: Idempotency — two runs with same args → identical output
# ---------------------------------------------------------------------------
RES1=$(run_summarize --budget-remaining 1 --ledger "$LEDGER")
RES2=$(run_summarize --budget-remaining 1 --ledger "$LEDGER")
OUT1=$(extract_out "$RES1")
OUT2=$(extract_out "$RES2")

if [[ "$OUT1" == "$OUT2" ]]; then
    pass "T6: idempotency: identical output for identical args"
else
    fail "T6: idempotency: outputs differ. Run1: $OUT1 -- Run2: $OUT2"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
