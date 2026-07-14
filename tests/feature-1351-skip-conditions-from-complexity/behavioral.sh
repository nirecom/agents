#!/usr/bin/env bash
# tests/feature-1351-skip-conditions-from-complexity/behavioral.sh
# Tests: hooks/lib/workflow-state/skip-signal-resolver.js
# Tags: L1, workflow, speculative-skip, scope:issue-specific
#
# Behavioral cases SC-1..SC-25 (guarded on API_READY).
# Sourced by the dispatcher; can also run standalone.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ==========================================================================
# SC-1: 0-signal-sonnet + outline → {so_c1:true, so_c2:true}
# ==========================================================================
echo ""
echo "=== SC-1: sonnet+[] outline → so_c1/so_c2 true ==="
if [ "$API_READY" = "true" ]; then
    SID="sc1-$$"
    node_record "$SID" "low" '[]' >/dev/null
    assert_eq "SC-1. outline conditions from 0-signal-sonnet" '{"so_c1":true,"so_c2":true}' "$(node_resolve "$SID" outline)"
else
    skip "SC-1 (API absent)"
fi

# ==========================================================================
# SC-2: 0-signal-sonnet + detail → {sd_c1:true, sd_c2:true, sd_c3:true}
# ==========================================================================
echo ""
echo "=== SC-2: sonnet+[] detail → sd_c1/sd_c2/sd_c3 true ==="
if [ "$API_READY" = "true" ]; then
    SID="sc2-$$"
    node_record "$SID" "low" '[]' >/dev/null
    assert_eq "SC-2. detail conditions from 0-signal-sonnet" '{"sd_c1":true,"sd_c2":true,"sd_c3":true}' "$(node_resolve "$SID" detail)"
else
    skip "SC-2 (API absent)"
fi

# ==========================================================================
# SC-3: opus + non-empty signals + outline → null
# ==========================================================================
echo ""
echo "=== SC-3: opus+[S1] outline → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc3-$$"
    node_record "$SID" "high" '["S1-multi-file"]' >/dev/null
    assert_eq "SC-3. opus verdict → null (outline)" 'null' "$(node_resolve "$SID" outline)"
else
    skip "SC-3 (API absent)"
fi
# SC-8: verdict guard is load-bearing — opus+signals:[] intentionally returns null (see detail.md accepted tradeoffs)

# ==========================================================================
# SC-4: opus + non-empty signals + detail → null
# ==========================================================================
echo ""
echo "=== SC-4: opus+[S1] detail → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc4-$$"
    node_record "$SID" "high" '["S1-multi-file"]' >/dev/null
    assert_eq "SC-4. opus verdict → null (detail)" 'null' "$(node_resolve "$SID" detail)"
else
    skip "SC-4 (API absent)"
fi

# ==========================================================================
# SC-5: no state file → null (fail-open)
# ==========================================================================
echo ""
echo "=== SC-5: missing state → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc5-missing-$$"
    assert_eq "SC-5. missing state file → null" 'null' "$(node_resolve "$SID" outline)"
else
    skip "SC-5 (API absent)"
fi

# ==========================================================================
# SC-6: invalid targetStep → null
# ==========================================================================
echo ""
echo "=== SC-6: sonnet+[] bogus step → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc6-$$"
    node_record "$SID" "low" '[]' >/dev/null
    assert_eq "SC-6. invalid targetStep → null" 'null' "$(node_resolve "$SID" bogus)"
else
    skip "SC-6 (API absent)"
fi

# ==========================================================================
# SC-7: sonnet with signals present → null (signals must be empty)
# ==========================================================================
echo ""
echo "=== SC-7: sonnet+[S1,S2] detail → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc7-$$"
    node_record "$SID" "low" '["S1","S2"]' >/dev/null
    assert_eq "SC-7. sonnet with non-empty signals → null" 'null' "$(node_resolve "$SID" detail)"
else
    skip "SC-7 (API absent)"
fi

# ==========================================================================
# SC-8: high level + signals:[] → null (verdict guard, SC-8 load-bearing)
# ==========================================================================
echo ""
echo "=== SC-8: high verdict + empty signals → null (verdict guard) ==="
if [ "$API_READY" = "true" ]; then
    SID="sc8-$$"
    record_high_empty_signals "$SID"
    assert_eq "SC-8. high+[] → null (verdict guard, not signals-only)" 'null' "$(node_resolve "$SID" outline)"
else
    skip "SC-8 (API absent)"
fi

# ==========================================================================
# SC-9: corrupt JSON state → null (fail-open, try/catch)
# ==========================================================================
echo ""
echo "=== SC-9: corrupt JSON state → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc9-$$"
    write_raw_state "$SID" '{invalid json'
    assert_eq "SC-9. corrupt state file → null" 'null' "$(node_resolve "$SID" outline)"
else
    skip "SC-9 (API absent)"
fi

# ==========================================================================
# SC-10: detail return has EXACTLY the CONDITION_SCHEMAS.detail keys (no extras)
# ==========================================================================
echo ""
echo "=== SC-10: detail return keys match CONDITION_SCHEMAS.detail exactly ==="
if [ "$API_READY" = "true" ]; then
    SID="sc10-$$"
    node_record "$SID" "low" '[]' >/dev/null
    SC10_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$SID', 'detail');
    const expected = r.CONDITION_SCHEMAS.detail.slice().sort();
    const actual = Object.keys(v).sort();
    const same = actual.length === expected.length && actual.every((k, i) => k === expected[i]);
    console.log(same ? 'MATCH' : 'MISMATCH:' + JSON.stringify(actual));
  " 2>/dev/null)"
    assert_eq "SC-10. detail keys === CONDITION_SCHEMAS.detail (exact set)" 'MATCH' "$SC10_OUT"
else
    skip "SC-10 (API absent)"
fi

# ==========================================================================
# SC-11: outline values are strictly === true (not merely truthy)
# ==========================================================================
echo ""
echo "=== SC-11: outline values strictly === true ==="
if [ "$API_READY" = "true" ]; then
    SID="sc11-$$"
    node_record "$SID" "low" '[]' >/dev/null
    SC11_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$SID', 'outline');
    const allStrictTrue = Object.values(v).every((x) => x === true);
    console.log(allStrictTrue ? 'STRICT_TRUE' : 'NOT_STRICT:' + JSON.stringify(Object.values(v)));
  " 2>/dev/null)"
    assert_eq "SC-11. outline values strictly === true" 'STRICT_TRUE' "$SC11_OUT"
else
    skip "SC-11 (API absent)"
fi

# ==========================================================================
# SC-12..SC-16: malformed complexity_evaluation fields → null (C4 coverage)
# ==========================================================================
echo ""
echo "=== SC-12..SC-16: malformed CE fields → null (fail-open) ==="
if [ "$API_READY" = "true" ]; then
    SID="sc12-$$"
    write_ce_state "$SID" '{"level":"low","signals":null,"recorded_at":"2026-01-01T00:00:00Z"}'
    assert_eq "SC-12. signals:null → null" 'null' "$(node_resolve "$SID" outline)"

    SID="sc13-$$"
    write_ce_state "$SID" '{"level":"low","signals":"","recorded_at":"2026-01-01T00:00:00Z"}'
    assert_eq "SC-13. signals:\"\" (string) → null" 'null' "$(node_resolve "$SID" outline)"

    SID="sc14-$$"
    write_ce_state "$SID" '{"level":"low","recorded_at":"2026-01-01T00:00:00Z"}'
    assert_eq "SC-14. missing signals field → null" 'null' "$(node_resolve "$SID" outline)"

    SID="sc15-$$"
    write_ce_state "$SID" '{"signals":[],"recorded_at":"2026-01-01T00:00:00Z"}'
    assert_eq "SC-15. missing level field → null" 'null' "$(node_resolve "$SID" outline)"

    SID="sc16-$$"
    write_ce_state "$SID" '{"level":"","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}'
    assert_eq "SC-16. level:\"\" → null" 'null' "$(node_resolve "$SID" outline)"
else
    skip "SC-12..SC-16 (API absent)"
    skip "SC-12..SC-16 (API absent)"
    skip "SC-12..SC-16 (API absent)"
    skip "SC-12..SC-16 (API absent)"
    skip "SC-12..SC-16 (API absent)"
fi

# ==========================================================================
# SC-17: idempotency — two calls return identical result
# ==========================================================================
echo ""
echo "=== SC-17: idempotency — two calls return identical result ==="
if [ "$API_READY" = "true" ]; then
    SID="sc17-$$"
    node_record "$SID" "low" '[]' >/dev/null
    R1="$(node_resolve "$SID" outline)"
    R2="$(node_resolve "$SID" outline)"
    assert_eq "SC-17. idempotent: second call matches first" "$R1" "$R2"
else
    skip "SC-17 (API absent)"
fi

# ==========================================================================
# SC-18: adversarial sessionId (path traversal attempt) → null or safe-error
# ==========================================================================
echo ""
echo "=== SC-18: adversarial sessionId → null (no path traversal) ==="
if [ "$API_READY" = "true" ]; then
    ADV_OUT="$(node_resolve "../../../etc/passwd" outline 2>/dev/null || echo "null")"
    assert_eq "SC-18. path-traversal sessionId → null" 'null' "$ADV_OUT"
else
    skip "SC-18 (API absent)"
fi

# ==========================================================================
# SC-18b: absolute-path sessionId → null (no traversal outside WORKFLOW_DIR)
# ==========================================================================
echo ""
echo "=== SC-18b: absolute-path sessionId → null ==="
if [ "$API_READY" = "true" ]; then
    ABS_OUT="$(node_resolve "/etc/passwd" outline 2>/dev/null || echo "null")"
    assert_eq "SC-18b. absolute-path sessionId → null" 'null' "$ABS_OUT"
else
    skip "SC-18b (API absent)"
fi

# ==========================================================================
# SC-19: single-element signals array → null (not treated as empty)
# ==========================================================================
echo ""
echo "=== SC-19: signals:[\"S1\"] (non-empty) → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc19-$$"
    node_record "$SID" "low" '["S1"]' >/dev/null
    assert_eq "SC-19. single-element signals → null" 'null' "$(node_resolve "$SID" outline)"
else
    skip "SC-19 (API absent)"
fi

# ==========================================================================
# SC-20: duplicate signals → null (non-empty, not a special case)
# ==========================================================================
echo ""
echo "=== SC-20: signals:[\"S1\",\"S1\"] → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc20-$$"
    node_record "$SID" "low" '["S1","S1"]' >/dev/null
    assert_eq "SC-20. duplicate signals → null" 'null' "$(node_resolve "$SID" outline)"
else
    skip "SC-20 (API absent)"
fi

# ==========================================================================
# SC-21: outline return has EXACTLY the CONDITION_SCHEMAS.outline keys
# ==========================================================================
echo ""
echo "=== SC-21: outline return keys match CONDITION_SCHEMAS.outline exactly ==="
if [ "$API_READY" = "true" ]; then
    SID="sc21-$$"
    node_record "$SID" "low" '[]' >/dev/null
    SC21_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$SID', 'outline');
    const expected = r.CONDITION_SCHEMAS.outline.slice().sort();
    const actual = Object.keys(v).sort();
    const same = actual.length === expected.length && actual.every((k, i) => k === expected[i]);
    console.log(same ? 'MATCH' : 'MISMATCH:' + JSON.stringify(actual));
  " 2>/dev/null)"
    assert_eq "SC-21. outline keys === CONDITION_SCHEMAS.outline (exact set)" 'MATCH' "$SC21_OUT"
else
    skip "SC-21 (API absent)"
fi

# ==========================================================================
# SC-22: sessionId with slash → null (assertValidSessionId rejects non-[A-Za-z0-9_-])
# ==========================================================================
echo ""
echo "=== SC-22: sessionId with slash → null ==="
if [ "$API_READY" = "true" ]; then
    SC22_OUT="$(node_resolve "a/b" outline 2>/dev/null || echo "null")"
    assert_eq "SC-22. slash in sessionId → null" 'null' "$SC22_OUT"
else
    skip "SC-22 (API absent)"
fi

# ==========================================================================
# SC-23: sessionId with semicolon → null
# ==========================================================================
echo ""
echo "=== SC-23: sessionId with semicolon → null ==="
if [ "$API_READY" = "true" ]; then
    SC23_OUT="$(node_resolve "a;b" outline 2>/dev/null || echo "null")"
    assert_eq "SC-23. semicolon in sessionId → null" 'null' "$SC23_OUT"
else
    skip "SC-23 (API absent)"
fi

# ==========================================================================
# SC-24: empty-string sessionId → null
# ==========================================================================
echo ""
echo "=== SC-24: empty sessionId → null ==="
if [ "$API_READY" = "true" ]; then
    SC24_OUT="$(node_resolve "" outline 2>/dev/null || echo "null")"
    assert_eq "SC-24. empty sessionId → null" 'null' "$SC24_OUT"
else
    skip "SC-24 (API absent)"
fi

# ==========================================================================
# SC-25: targetStep="" (empty string) → null
# ==========================================================================
echo ""
echo "=== SC-25: empty targetStep → null ==="
if [ "$API_READY" = "true" ]; then
    SID="sc25-$$"
    node_record "$SID" "low" '[]' >/dev/null
    SC25_OUT="$(node_resolve "$SID" "" 2>/dev/null || echo "null")"
    assert_eq "SC-25. empty targetStep → null" 'null' "$SC25_OUT"
else
    skip "SC-25 (API absent)"
fi
