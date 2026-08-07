# tests/feature-complexity-evaluation-resolver/api-cases.sh
# Tests: hooks/workflow-state/state-io.js, hooks/workflow-state/skip-signal-resolver.js
# Tags: L2, workflow, complexity-evaluation, scope:issue-specific
#
# Sourced by feature-complexity-evaluation-resolver.sh after lib.sh — no shebang,
# no runner; the cases run at source time, so the parent's source order IS the
# execution order. Owns the direct write/read API cases: CE-1..CE-9 (round-trip,
# has/read fail-open, invalid verdict, last-write-wins), CE-SCHEMA-1..5 (signal
# array edge cases, ISO recorded_at) and CE-CORRUPT-1..4 (hand-written state).
#
# Depends on lib.sh for: API_READY, WORKFLOW_DIR_N, STATEIO_N, run_with_timeout,
# node_record, node_read_field, node_read_json, node_has, write_raw_state,
# assert_eq, check_not_contains, pass, fail, skip.

# ==========================================================================
# CE-1: round-trip record+read (verdict=opus, signals non-empty)
# ==========================================================================
echo ""
echo "=== CE-1: round-trip record+read (opus, non-empty signals) ==="
if [ "$API_READY" = "true" ]; then
  SID="ce1-$$"
  node_record "$SID" "high" '["S1-multi-file","S2-architecture"]' >/dev/null
  assert_eq "CE-1a. level read-back = high" 'high' "$(node_read_field "$SID" level | tr -d '\"')"
  assert_eq "CE-1b. signals read-back preserved" '["S1-multi-file","S2-architecture"]' "$(node_read_field "$SID" signals)"
else
  skip "CE-1 (API absent)"
fi

# ==========================================================================
# CE-2: round-trip record+read (verdict=sonnet, signals empty)
# ==========================================================================
echo ""
echo "=== CE-2: round-trip record+read (sonnet, empty signals) ==="
if [ "$API_READY" = "true" ]; then
  SID="ce2-$$"
  node_record "$SID" "low" '[]' >/dev/null
  assert_eq "CE-2a. level read-back = low" 'low' "$(node_read_field "$SID" level | tr -d '\"')"
  assert_eq "CE-2b. empty signals read-back = []" '[]' "$(node_read_field "$SID" signals)"
else
  skip "CE-2 (API absent)"
fi

# ==========================================================================
# CE-3: hasComplexityEvaluation → true after record
# ==========================================================================
echo ""
echo "=== CE-3: hasComplexityEvaluation → true after record ==="
if [ "$API_READY" = "true" ]; then
  SID="ce3-$$"
  node_record "$SID" "high" '["S1-multi-file"]' >/dev/null
  assert_eq "CE-3. hasComplexityEvaluation true after record" 'true' "$(node_has "$SID")"
else
  skip "CE-3 (API absent)"
fi

# ===========
# CE-3b: hasComplexityEvaluation → true after record (level=low)
# ===========
echo ""
echo "=== CE-3b: hasComplexityEvaluation → true after record (level=low) ==="
if [ "$API_READY" = "true" ]; then
  SID="ce3b-$$"
  node_record "$SID" "low" '[]' >/dev/null
  assert_eq "CE-3b. hasComplexityEvaluation true after low record" 'true' "$(node_has "$SID")"
else
  skip "CE-3b (API absent)"
fi

# ==========================================================================
# CE-4: hasComplexityEvaluation → false when state file absent (fail-open)
# ==========================================================================
echo ""
echo "=== CE-4: hasComplexityEvaluation → false (state absent, fail-open) ==="
if [ "$API_READY" = "true" ]; then
  SID="ce4-missing-$$"
  assert_eq "CE-4. hasComplexityEvaluation false when state absent" 'false' "$(node_has "$SID")"
else
  skip "CE-4 (API absent)"
fi

# ==========================================================================
# CE-5: readComplexityEvaluation → null when state file absent
# ==========================================================================
echo ""
echo "=== CE-5: readComplexityEvaluation → null (state absent) ==="
if [ "$API_READY" = "true" ]; then
  SID="ce5-missing-$$"
  assert_eq "CE-5. readComplexityEvaluation null when state absent" 'null' "$(node_read_json "$SID")"
else
  skip "CE-5 (API absent)"
fi

# ==========================================================================
# CE-6: invalid verdict ("invalid") → throw (write API rejects)
# ==========================================================================
echo ""
echo "=== CE-6: invalid verdict → throw ==="
if [ "$API_READY" = "true" ]; then
  SID="ce6-$$"
  CE6_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    try {
      io.recordComplexityEvaluation('$SID', 'invalid', []);
      console.log('NO_THROW');
    } catch (e) {
      console.log('THREW');
    }
  " 2>/dev/null)"
  assert_eq "CE-6. invalid verdict throws" 'THREW' "$CE6_OUT"
else
  skip "CE-6 (API absent)"
fi

# ==========================================================================
# CE-7: object missing required fields → null (fail-open read)
# ==========================================================================
echo ""
echo "=== CE-7: complexity record missing required fields → null ==="
if [ "$API_READY" = "true" ]; then
  SID="ce7-$$"
  # Hand-craft a state file whose complexity_evaluation lacks the level field.
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.createInitialState('$SID');
    s.complexity_evaluation = { signals: [], recorded_at: new Date().toISOString() };
    io.writeState('$SID', s);
  " 2>/dev/null
  assert_eq "CE-7. partial complexity record reads null" 'null' "$(node_read_json "$SID")"
else
  skip "CE-7 (API absent)"
fi

# ==========================================================================
# CE-8: non-array signals field → null (fail-open, C2 fix: !Array.isArray)
# ==========================================================================
echo ""
echo "=== CE-8: non-array signals field → null (C2 fix) ==="
if [ "$API_READY" = "true" ]; then
  SID="ce8-$$"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.createInitialState('$SID');
    s.complexity_evaluation = { level: 'high', signals: 'S1-multi-file', recorded_at: new Date().toISOString() };
    io.writeState('$SID', s);
  " 2>/dev/null
  assert_eq "CE-8. non-array signals reads null" 'null' "$(node_read_json "$SID")"
else
  skip "CE-8 (API absent)"
fi

# ==========================================================================
# CE-9: double record → last-write-wins (idempotency)
# ==========================================================================
echo ""
echo "=== CE-9: double record → last-write-wins ==="
if [ "$API_READY" = "true" ]; then
  SID="ce9-$$"
  node_record "$SID" "high" '["S1-multi-file"]' >/dev/null
  node_record "$SID" "low" '[]' >/dev/null
  assert_eq "CE-9a. level = last write (low)" 'low' "$(node_read_field "$SID" level | tr -d '\"')"
  assert_eq "CE-9b. signals = last write ([])" '[]' "$(node_read_field "$SID" signals)"
else
  skip "CE-9 (API absent)"
fi

# ==========================================================================
# C7 — schema edge cases (all S1-S6 present, duplicates, unknown, long, ISO)
# ==========================================================================
echo ""
echo "=== CE-SCHEMA-1: all S1..S6 signals round-trip ==="
if [ "$API_READY" = "true" ]; then
  SID="ceall-$$"
  node_record "$SID" "high" '["S1","S2","S3","S4","S5","S6"]' >/dev/null
  assert_eq "CE-SCHEMA-1. all six signals preserved" '["S1","S2","S3","S4","S5","S6"]' "$(node_read_field "$SID" signals)"
else
  skip "CE-SCHEMA-1 (API absent)"
fi

echo ""
echo "=== CE-SCHEMA-2: duplicate signal ids preserved verbatim (no dedup) ==="
if [ "$API_READY" = "true" ]; then
  SID="cedup-$$"
  node_record "$SID" "high" '["S1","S1","S2"]' >/dev/null
  assert_eq "CE-SCHEMA-2. duplicates stored as-is" '["S1","S1","S2"]' "$(node_read_field "$SID" signals)"
else
  skip "CE-SCHEMA-2 (API absent)"
fi

echo ""
echo "=== CE-SCHEMA-3: unknown signal name stored (no value validation) ==="
if [ "$API_READY" = "true" ]; then
  SID="ceunk-$$"
  node_record "$SID" "high" '["unknown-signal"]' >/dev/null
  assert_eq "CE-SCHEMA-3. unknown signal accepted" '["unknown-signal"]' "$(node_read_field "$SID" signals)"
else
  skip "CE-SCHEMA-3 (API absent)"
fi

echo ""
echo "=== CE-SCHEMA-4: very long signal string stored intact ==="
if [ "$API_READY" = "true" ]; then
  SID="celong-$$"
  LONG="$(printf 'S%.0s' $(seq 1 300))"
  node_record "$SID" "low" "[\"$LONG\"]" >/dev/null
  assert_eq "CE-SCHEMA-4. long signal preserved" "[\"$LONG\"]" "$(node_read_field "$SID" signals)"
else
  skip "CE-SCHEMA-4 (API absent)"
fi

echo ""
echo "=== CE-SCHEMA-5: recorded_at is ISO 8601 ==="
if [ "$API_READY" = "true" ]; then
  SID="ceiso-$$"
  node_record "$SID" "high" '["S1"]' >/dev/null
  ISO_VAL="$(node_read_field "$SID" recorded_at | tr -d '\"')"
  if printf '%s' "$ISO_VAL" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
    pass "CE-SCHEMA-5. recorded_at ISO 8601 [$ISO_VAL]"
  else
    fail "CE-SCHEMA-5. recorded_at not ISO 8601 -- got [$ISO_VAL]"
  fi
else
  skip "CE-SCHEMA-5 (API absent)"
fi

# ==========================================================================
# C8 — corrupt JSON / type errors (direct state-file manipulation)
# ==========================================================================
echo ""
echo "=== CE-CORRUPT-1: malformed JSON state file → null (fail-open) ==="
if [ "$API_READY" = "true" ]; then
  SID="cecorrupt-$$"
  write_raw_state "$SID" '{invalid json'
  assert_eq "CE-CORRUPT-1. malformed JSON reads null" 'null' "$(node_read_json "$SID")"
else
  skip "CE-CORRUPT-1 (API absent)"
fi

echo ""
echo "=== CE-CORRUPT-2: complexity_evaluation is a string → null ==="
if [ "$API_READY" = "true" ]; then
  SID="cestr-$$"
  write_raw_state "$SID" '{"session_id":"cestr","complexity_evaluation":"opus"}'
  assert_eq "CE-CORRUPT-2. string complexity_evaluation reads null" 'null' "$(node_read_json "$SID")"
else
  skip "CE-CORRUPT-2 (API absent)"
fi

echo ""
echo "=== CE-CORRUPT-3: recorded_at missing → null (fail-open) ==="
if [ "$API_READY" = "true" ]; then
  SID="cenorec-$$"
  write_raw_state "$SID" '{"session_id":"cenorec","complexity_evaluation":{"level":"high","signals":["S1"]}}'
  assert_eq "CE-CORRUPT-3. missing recorded_at reads null" 'null' "$(node_read_json "$SID")"
else
  skip "CE-CORRUPT-3 (API absent)"
fi

echo ""
echo "=== CE-CORRUPT-4: non-string signal element still stored (no element validation) ==="
if [ "$API_READY" = "true" ]; then
  SID="ceelem-$$"
  # signals is a valid array; element-level type is NOT validated by the read API.
  write_raw_state "$SID" '{"session_id":"ceelem","complexity_evaluation":{"level":"high","signals":[1,2],"recorded_at":"2026-07-11T00:00:00.000Z"}}'
  RES="$(node_read_json "$SID")"
  check_not_contains "CE-CORRUPT-4. array-of-numbers signals NOT rejected as null" "null" "$RES"
else
  skip "CE-CORRUPT-4 (API absent)"
fi
