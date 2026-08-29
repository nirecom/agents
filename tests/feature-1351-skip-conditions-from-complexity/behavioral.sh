#!/usr/bin/env bash
# tests/feature-1351-skip-conditions-from-complexity/behavioral.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js
# Tags: L1, workflow, speculative-skip, scope:issue-specific
#
# Behavioral cases SC-1..SC-25 — unconditional. The required-member assertion
# lives in _lib.sh (SC-API); a missing member fails there and again here, and is
# never converted into a SKIP (R3-C7).
# Sourced by the dispatcher; can also run standalone.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ==========================================================================
# SC-1: 0-signal-sonnet + outline → {so_c1:true, so_c2:true}
# ==========================================================================
echo ""
echo "=== SC-1: sonnet+[] outline → so_c1/so_c2 true ==="
SID="sc1-$$"
node_record "$SID" '[]' >/dev/null
assert_eq "SC-1. outline conditions from 0-signal-sonnet" '{"so_c1":true,"so_c2":true}' "$(node_resolve "$SID" outline)"

# ==========================================================================
# SC-2: 0-signal-sonnet + detail → {sd_c1:true, sd_c2:true, sd_c3:true}
# ==========================================================================
echo ""
echo "=== SC-2: sonnet+[] detail → sd_c1/sd_c2/sd_c3 true ==="
SID="sc2-$$"
node_record "$SID" '[]' >/dev/null
assert_eq "SC-2. detail conditions from 0-signal-sonnet" '{"sd_c1":true,"sd_c2":true,"sd_c3":true}' "$(node_resolve "$SID" detail)"

# ==========================================================================
# SC-3: opus + non-empty signals + outline → null
# ==========================================================================
echo ""
echo "=== SC-3: opus+[S1] outline → null ==="
SID="sc3-$$"
node_record "$SID" '["S1-multi-file"]' >/dev/null
assert_eq "SC-3. opus verdict → null (outline)" 'null' "$(node_resolve "$SID" outline)"
# SC-8: verdict guard is load-bearing — opus+signals:[] intentionally returns null (see detail.md accepted tradeoffs)

# ==========================================================================
# SC-4: opus + non-empty signals + detail → null
# ==========================================================================
echo ""
echo "=== SC-4: opus+[S1] detail → null ==="
SID="sc4-$$"
node_record "$SID" '["S1-multi-file"]' >/dev/null
assert_eq "SC-4. opus verdict → null (detail)" 'null' "$(node_resolve "$SID" detail)"

# ==========================================================================
# SC-5: no state file → null (fail-open)
# ==========================================================================
echo ""
echo "=== SC-5: missing state → null ==="
SID="sc5-missing-$$"
assert_eq "SC-5. missing state file → null" 'null' "$(node_resolve "$SID" outline)"

# ==========================================================================
# SC-6: invalid targetStep → null
# ==========================================================================
echo ""
echo "=== SC-6: sonnet+[] bogus step → null ==="
SID="sc6-$$"
node_record "$SID" '[]' >/dev/null
assert_eq "SC-6. invalid targetStep → null" 'null' "$(node_resolve "$SID" bogus)"

# ==========================================================================
# SC-7: derived-low with signals present → null (signals must be empty)
# ==========================================================================
echo ""
echo "=== SC-7: low+[S1,S2] detail → null ==="
SID="sc7-$$"
node_record "$SID" '["S1","S2"]' >/dev/null
assert_eq "SC-7. derived-low with non-empty signals → null" 'null' "$(node_resolve "$SID" detail)"

# ==========================================================================
# SC-8: high level + signals:[] → null (verdict guard, SC-8 load-bearing)
# ==========================================================================
echo ""
echo "=== SC-8: high verdict + empty signals → null (verdict guard) ==="
SID="sc8-$$"
record_high_empty_signals "$SID"
# Pre-assertion: the injected record must actually be there. The previous
# seeder assigned a projection key before writeState(), which strips it —
# so this case was asserting "no record at all" and would have passed even
# if the level guard were deleted.
assert_eq "SC-8a. the high+[] record actually persists through the projection" \
    '{"level":"high","levels":null,"signals":[]}' \
    "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "SC-8. high+[] → null (verdict guard, not signals-only)" 'null' "$(node_resolve "$SID" outline)"

# ==========================================================================
# SC-9: corrupt JSON state → null (fail-open, try/catch)
# ==========================================================================
echo ""
echo "=== SC-9: corrupt JSON state → null ==="
SID="sc9-$$"
write_raw_state "$SID" '{invalid json'
assert_eq "SC-9. corrupt state file → null" 'null' "$(node_resolve "$SID" outline)"

# ==========================================================================
# SC-10: detail return has EXACTLY the CONDITION_SCHEMAS.detail keys (no extras)
# ==========================================================================
echo ""
echo "=== SC-10: detail return keys match CONDITION_SCHEMAS.detail exactly ==="
  SID="sc10-$$"
  node_record "$SID" '[]' >/dev/null
  SC10_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
  const r = require('$RESOLVER_N');
  const v = r.resolveSkipConditionsFromComplexity('$SID', 'detail');
  const expected = r.CONDITION_SCHEMAS.detail.slice().sort();
  const actual = Object.keys(v).sort();
  const same = actual.length === expected.length && actual.every((k, i) => k === expected[i]);
  console.log(same ? 'MATCH' : 'MISMATCH:' + JSON.stringify(actual));
" 2>/dev/null)"
  assert_eq "SC-10. detail keys === CONDITION_SCHEMAS.detail (exact set)" 'MATCH' "$SC10_OUT"

# ==========================================================================
# SC-11: outline values are strictly === true (not merely truthy)
# ==========================================================================
echo ""
echo "=== SC-11: outline values strictly === true ==="
  SID="sc11-$$"
  node_record "$SID" '[]' >/dev/null
  SC11_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
  const r = require('$RESOLVER_N');
  const v = r.resolveSkipConditionsFromComplexity('$SID', 'outline');
  const allStrictTrue = Object.values(v).every((x) => x === true);
  console.log(allStrictTrue ? 'STRICT_TRUE' : 'NOT_STRICT:' + JSON.stringify(Object.values(v)));
" 2>/dev/null)"
  assert_eq "SC-11. outline values strictly === true" 'STRICT_TRUE' "$SC11_OUT"

# ==========================================================================
# SC-12..SC-17b: malformed complexity_evaluation records, injected through the
# REAL event store (see inject_ce_event in _lib.sh — the old seeder wrote a
# projection key that persist silently strips, so these cases were testing an
# absent record). Each case first pins WHAT THE PROJECTION ACTUALLY FOLDED, then
# the resolver behaviour that follows. Split: malformed `signals` is NORMALIZED
# to [] and auto-skips as a legitimate 0-signal record; malformed `level`
# survives unnormalized to the resolver's own guard and fails open.
# ==========================================================================
echo ""
echo "=== SC-12..SC-17b: malformed CE records via the real event store ==="
SID="sc12-$$"
inject_ce_event "$SID" "{ level: 'low', signals: null }"
assert_eq "SC-12a. signals:null is normalized to [] by the projection" \
    '{"level":"low","levels":null,"signals":[]}' "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "SC-12. signals:null reaches the resolver as 0-signal-low → auto-skip" \
    '{"so_c1":true,"so_c2":true}' "$(node_resolve "$SID" outline)"

SID="sc13-$$"
inject_ce_event "$SID" "{ level: 'low', signals: 'S1-multi-file' }"
assert_eq "SC-13a. a string signals value is normalized to [] (the token is NOT kept)" \
    '{"level":"low","levels":null,"signals":[]}' "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "SC-13. string signals reaches the resolver as 0-signal-low → auto-skip" \
    '{"so_c1":true,"so_c2":true}' "$(node_resolve "$SID" outline)"

SID="sc14-$$"
inject_ce_event "$SID" "{ level: 'low' }"
assert_eq "SC-14a. a missing signals field is filled in as []" \
    '{"level":"low","levels":null,"signals":[]}' "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "SC-14. missing signals reaches the resolver as 0-signal-low → auto-skip" \
    '{"so_c1":true,"so_c2":true}' "$(node_resolve "$SID" outline)"

# SC-15/SC-16: `level` is NOT normalized, so the resolver's own guard is
# what these two pin — and unlike SC-12..14 they can only fail open.
SID="sc15-$$"
inject_ce_event "$SID" "{ signals: [] }"
assert_eq "SC-15a. a missing level survives the projection unfilled" \
    '{"levels":null,"signals":[]}' "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "SC-15. missing level field → null" 'null' "$(node_resolve "$SID" outline)"

SID="sc16-$$"
inject_ce_event "$SID" "{ level: '', signals: [] }"
assert_eq "SC-16a. an empty level survives the projection verbatim" \
    '{"level":"","levels":null,"signals":[]}' "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "SC-16. level:\"\" → null" 'null' "$(node_resolve "$SID" outline)"

# SC-17a/b: low PLUS non-empty signals — a self-contradictory record that
# recordComplexityEvaluation can no longer produce (#2099 derives the level
# from the signals), so only injection reaches it. The signals-empty guard,
# not the level, is what must reject it.
SID="sc17lo-$$"
inject_ce_event "$SID" "{ level: 'low', signals: ['S1-multi-file'] }"
assert_eq "SC-17a. the low+non-empty-signals record persists verbatim" \
    '{"level":"low","levels":null,"signals":["S1-multi-file"]}' \
    "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "SC-17b. low with non-empty signals → null (never auto-skip)" \
    'null' "$(node_resolve "$SID" outline)"

# ==========================================================================
# SC-17: idempotency — two calls return identical result
# ==========================================================================
echo ""
echo "=== SC-17: idempotency — two calls return identical result ==="
SID="sc17-$$"
node_record "$SID" '[]' >/dev/null
R1="$(node_resolve "$SID" outline)"
R2="$(node_resolve "$SID" outline)"
assert_eq "SC-17. idempotent: second call matches first" "$R1" "$R2"

# ==========================================================================
# SC-18: adversarial sessionId (path traversal attempt) → null or safe-error
# ==========================================================================
echo ""
echo "=== SC-18: adversarial sessionId → null (no path traversal) ==="
ADV_OUT="$(node_resolve "../../../etc/passwd" outline 2>/dev/null || echo "null")"
assert_eq "SC-18. path-traversal sessionId → null" 'null' "$ADV_OUT"

# ==========================================================================
# SC-18b: absolute-path sessionId → null (no traversal outside WORKFLOW_DIR)
# ==========================================================================
echo ""
echo "=== SC-18b: absolute-path sessionId → null ==="
ABS_OUT="$(node_resolve "/etc/passwd" outline 2>/dev/null || echo "null")"
assert_eq "SC-18b. absolute-path sessionId → null" 'null' "$ABS_OUT"

# ==========================================================================
# SC-19: single-element signals array → null (not treated as empty)
# ==========================================================================
echo ""
echo "=== SC-19: signals:[\"S1\"] (non-empty) → null ==="
SID="sc19-$$"
node_record "$SID" '["S1"]' >/dev/null
assert_eq "SC-19. single-element signals → null" 'null' "$(node_resolve "$SID" outline)"

# ==========================================================================
# SC-20: duplicate signals → null (non-empty, not a special case)
# ==========================================================================
echo ""
echo "=== SC-20: signals:[\"S1\",\"S1\"] → null ==="
SID="sc20-$$"
node_record "$SID" '["S1","S1"]' >/dev/null
assert_eq "SC-20. duplicate signals → null" 'null' "$(node_resolve "$SID" outline)"

# ==========================================================================
# SC-21: outline return has EXACTLY the CONDITION_SCHEMAS.outline keys
# ==========================================================================
echo ""
echo "=== SC-21: outline return keys match CONDITION_SCHEMAS.outline exactly ==="
  SID="sc21-$$"
  node_record "$SID" '[]' >/dev/null
  SC21_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
  const r = require('$RESOLVER_N');
  const v = r.resolveSkipConditionsFromComplexity('$SID', 'outline');
  const expected = r.CONDITION_SCHEMAS.outline.slice().sort();
  const actual = Object.keys(v).sort();
  const same = actual.length === expected.length && actual.every((k, i) => k === expected[i]);
  console.log(same ? 'MATCH' : 'MISMATCH:' + JSON.stringify(actual));
" 2>/dev/null)"
  assert_eq "SC-21. outline keys === CONDITION_SCHEMAS.outline (exact set)" 'MATCH' "$SC21_OUT"

# ==========================================================================
# SC-22: sessionId with slash → null (assertValidSessionId rejects non-[A-Za-z0-9_-])
# ==========================================================================
echo ""
echo "=== SC-22: sessionId with slash → null ==="
SC22_OUT="$(node_resolve "a/b" outline 2>/dev/null || echo "null")"
assert_eq "SC-22. slash in sessionId → null" 'null' "$SC22_OUT"

# ==========================================================================
# SC-23: sessionId with semicolon → null
# ==========================================================================
echo ""
echo "=== SC-23: sessionId with semicolon → null ==="
SC23_OUT="$(node_resolve "a;b" outline 2>/dev/null || echo "null")"
assert_eq "SC-23. semicolon in sessionId → null" 'null' "$SC23_OUT"

# ==========================================================================
# SC-24: empty-string sessionId → null
# ==========================================================================
echo ""
echo "=== SC-24: empty sessionId → null ==="
SC24_OUT="$(node_resolve "" outline 2>/dev/null || echo "null")"
assert_eq "SC-24. empty sessionId → null" 'null' "$SC24_OUT"

# ==========================================================================
# SC-25: targetStep="" (empty string) → null
# ==========================================================================
echo ""
echo "=== SC-25: empty targetStep → null ==="
SID="sc25-$$"
node_record "$SID" '[]' >/dev/null
SC25_OUT="$(node_resolve "$SID" "" 2>/dev/null || echo "null")"
assert_eq "SC-25. empty targetStep → null" 'null' "$SC25_OUT"
