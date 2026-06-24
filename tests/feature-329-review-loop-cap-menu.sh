#!/usr/bin/env bash
# Tests: bin/review-loop-cap-menu
# Tags: bin, env, config, loop, tests, scope:common
# Tests for bin/review-loop-cap-menu (issue #329).
# Verifies JSON output schema, options invariants, auto-extend exit 42,
# and arg-validation exit 2.
#
# Source file does not exist yet — tests will FAIL until implemented.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-loop-cap-menu"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

# Helper: run script and capture stdout + exit code separately
run_menu() {
    local exit_code=0
    local out
    out=$(_timeout bash "$SCRIPT" "$@" 2>&1) || exit_code=$?
    printf '%s\n__RC__%d\n' "$out" "$exit_code"
}

extract_rc() {
    echo "$1" | grep '^__RC__' | sed 's/__RC__//'
}

extract_out() {
    echo "$1" | sed '/^__RC__/d'
}

# Verify jq is available — needed by the JSON schema tests
if ! command -v jq >/dev/null 2>&1; then
    fail "jq not installed — required for JSON schema tests"
    echo ""
    echo "$ERRORS test(s) failed."
    exit 1
fi

# Skip body if SCRIPT doesn't exist (don't crash with bash: not found),
# but still emit fails for each expected test.
SCRIPT_EXISTS=true
if [[ ! -f "$SCRIPT" ]]; then
    SCRIPT_EXISTS=false
fi

# ---------------------------------------------------------------------------
# 1. --budget-remaining 2: valid JSON, has "extend", absolute_ceiling=false
# ---------------------------------------------------------------------------
RES=$(run_menu --budget-remaining 2)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "budget=2: exit 0"
else
    fail "budget=2: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | jq -e . >/dev/null 2>&1; then
    pass "budget=2: stdout is valid JSON"
    if echo "$OUT" | jq -e '.options | map(.value) | index("extend")' >/dev/null 2>&1; then
        pass "budget=2: options contains 'extend'"
    else
        fail "budget=2: options does NOT contain 'extend'. JSON: $OUT"
    fi
    if [[ "$(echo "$OUT" | jq -r '.absolute_ceiling' 2>/dev/null)" == "false" ]]; then
        pass "budget=2: absolute_ceiling=false"
    else
        fail "budget=2: absolute_ceiling != false. JSON: $OUT"
    fi
else
    fail "budget=2: stdout is not valid JSON. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 2. --budget-remaining 0: no "extend"; absolute_ceiling=true; only land+adjust
# ---------------------------------------------------------------------------
RES=$(run_menu --budget-remaining 0)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "budget=0: exit 0"
else
    fail "budget=0: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | jq -e . >/dev/null 2>&1; then
    pass "budget=0: stdout is valid JSON"
    # extend MUST NOT be in options
    if echo "$OUT" | jq -e '.options | map(.value) | index("extend") | not' >/dev/null 2>&1; then
        pass "budget=0: 'extend' absent from options"
    else
        fail "budget=0: 'extend' unexpectedly present. JSON: $OUT"
    fi
    if [[ "$(echo "$OUT" | jq -r '.absolute_ceiling' 2>/dev/null)" == "true" ]]; then
        pass "budget=0: absolute_ceiling=true"
    else
        fail "budget=0: absolute_ceiling != true. JSON: $OUT"
    fi
    VALUES=$(echo "$OUT" | jq -r '.options[].value' 2>/dev/null | tr -d '\r' | sort | tr '\n' ',')
    if [[ "$VALUES" == "adjust,land," ]]; then
        pass "budget=0: options contains exactly land and adjust"
    else
        fail "budget=0: options should be exactly land+adjust. Got: $VALUES"
    fi
else
    fail "budget=0: stdout is not valid JSON. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 3. --budget-remaining 1: has "extend"; exit 0
# ---------------------------------------------------------------------------
RES=$(run_menu --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "budget=1: exit 0"
else
    fail "budget=1: expected exit 0, got $RC"
fi

if echo "$OUT" | jq -e '.options | map(.value) | index("extend")' >/dev/null 2>&1; then
    pass "budget=1: 'extend' present in options"
else
    fail "budget=1: 'extend' missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 4. AUTO_EXTEND: budget=1 + all-high=true + cc-agrees-high=true → exit 42
# ---------------------------------------------------------------------------
RES=$(run_menu --budget-remaining 1 --all-high true --cc-agrees-high true)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "42" ]]; then
    pass "AUTO_EXTEND: exit 42 when all-high + cc-agrees-high + budget>0"
else
    fail "AUTO_EXTEND: expected exit 42, got $RC. Output: $OUT"
fi

# No JSON on stdout in AUTO_EXTEND case
# (some leading text is fine, but no parseable JSON object is expected)
if echo "$OUT" | jq -e . >/dev/null 2>&1; then
    fail "AUTO_EXTEND: stdout should not be JSON in auto-extend case. Output: $OUT"
else
    pass "AUTO_EXTEND: no JSON on stdout"
fi

# ---------------------------------------------------------------------------
# 5. Negative budget → exit 2
# ---------------------------------------------------------------------------
RES=$(run_menu --budget-remaining -1)
RC=$(extract_rc "$RES")
if [[ "$RC" == "2" ]]; then
    pass "negative budget: exit 2 (arg error)"
else
    fail "negative budget: expected exit 2, got $RC"
fi

# ---------------------------------------------------------------------------
# 6. Missing --budget-remaining → exit 2
# ---------------------------------------------------------------------------
RES=$(run_menu)
RC=$(extract_rc "$RES")
if [[ "$RC" == "2" ]]; then
    pass "missing --budget-remaining: exit 2"
else
    fail "missing --budget-remaining: expected exit 2, got $RC"
fi

# ---------------------------------------------------------------------------
# 7. Schema completeness: all top-level fields present
# ---------------------------------------------------------------------------
RES=$(run_menu --budget-remaining 2)
OUT=$(extract_out "$RES")
SCHEMA_OK=true
for field in question label budget_remaining options absolute_ceiling default; do
    if ! echo "$OUT" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1; then
        SCHEMA_OK=false
        fail "schema: missing required field '$field'. JSON: $OUT"
    fi
done
if $SCHEMA_OK; then
    pass "schema: all required fields present (question, label, budget_remaining, options, absolute_ceiling, default)"
fi

# ---------------------------------------------------------------------------
# 8. Idempotency: two runs → identical JSON
# ---------------------------------------------------------------------------
RES1=$(run_menu --budget-remaining 2 --label "foo")
RES2=$(run_menu --budget-remaining 2 --label "foo")
OUT1=$(extract_out "$RES1")
OUT2=$(extract_out "$RES2")
if [[ "$OUT1" == "$OUT2" ]]; then
    pass "idempotency: identical JSON for identical args"
else
    fail "idempotency: outputs differ. Run1: $OUT1 -- Run2: $OUT2"
fi

# ---------------------------------------------------------------------------
# 9. --label "foo" → JSON .label == "foo"
# ---------------------------------------------------------------------------
RES=$(run_menu --budget-remaining 2 --label "foo")
OUT=$(extract_out "$RES")
LABEL=$(echo "$OUT" | jq -r '.label' 2>/dev/null)
if [[ "$LABEL" == "foo" ]]; then
    pass "--label: JSON .label == 'foo'"
else
    fail "--label: expected .label='foo', got '$LABEL'. JSON: $OUT"
fi

# ---------------------------------------------------------------------------
# 10. CONV_LANG=japanese: valid JSON, question is non-empty
# ---------------------------------------------------------------------------
RES=$(CONV_LANG=japanese run_menu --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")
if [[ "$RC" == "0" ]]; then
    pass "CONV_LANG=japanese: exit 0"
else
    fail "CONV_LANG=japanese: expected exit 0, got $RC. Output: $OUT"
fi
if echo "$OUT" | jq -e '.question | length > 0' >/dev/null 2>&1; then
    pass "CONV_LANG=japanese: question field non-empty"
else
    fail "CONV_LANG=japanese: question field empty. JSON: $OUT"
fi

# ---------------------------------------------------------------------------
# 11. CONV_LANG=japanese: value fields stable (land/adjust/extend)
# ---------------------------------------------------------------------------
RES=$(CONV_LANG=japanese run_menu --budget-remaining 1)
OUT=$(extract_out "$RES")
VALUES=$(echo "$OUT" | jq -r '.options[].value' 2>/dev/null | tr -d '\r' | sort | tr '\n' ',')
if [[ "$VALUES" == "adjust,extend,land," ]]; then
    pass "CONV_LANG=japanese: value fields stable (land/adjust/extend)"
else
    fail "CONV_LANG=japanese: value fields wrong. Got: $VALUES"
fi

# ---------------------------------------------------------------------------
# 12. CONV_LANG=french (unsupported — English fallback): valid JSON
# ---------------------------------------------------------------------------
RES=$(CONV_LANG=french run_menu --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")
if [[ "$RC" == "0" ]] && echo "$OUT" | jq -e . >/dev/null 2>&1; then
    pass "CONV_LANG=french: exit 0, valid JSON (English fallback)"
else
    fail "CONV_LANG=french: expected exit 0 + valid JSON, got RC=$RC. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 13. CONV_LANG="" (empty): valid JSON, same as no CONV_LANG
# ---------------------------------------------------------------------------
RES=$(CONV_LANG="" run_menu --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")
if [[ "$RC" == "0" ]] && echo "$OUT" | jq -e . >/dev/null 2>&1; then
    pass "CONV_LANG='': exit 0, valid JSON"
else
    fail "CONV_LANG='': expected exit 0 + valid JSON, got RC=$RC. Output: $OUT"
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
