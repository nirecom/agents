# tests/feature-complexity-evaluation-resolver/api-cases.sh
# Tests: hooks/workflow-state/state-io.js, hooks/workflow-state/skip-signal-resolver.js
# Tags: L2, workflow, complexity-evaluation, scope:issue-specific
#
# Sourced by feature-complexity-evaluation-resolver.sh after lib.sh (which owns
# every helper used here); cases run at source time. Covers the direct
# write/read API: CE-1..CE-9, CE-SCHEMA-1..5, CE-CORRUPT-1..4.

# ==========================================================================
# CE-1: round-trip record+read (escalating signals)
# ==========================================================================
echo ""
echo "=== CE-1: round-trip record+read (escalating signals) ==="
SID="ce1-$$"
node_record "$SID" '["S1-multi-file","S2-architecture"]' >/dev/null
assert_eq "CE-1a. level read-back = high" 'high' "$(node_read_field "$SID" level | tr -d '\"')"
assert_eq "CE-1b. signals read-back preserved" '["S1-multi-file","S2-architecture"]' "$(node_read_field "$SID" signals)"

# ==========================================================================
# CE-2: round-trip record+read (zero signals)
# ==========================================================================
echo ""
echo "=== CE-2: round-trip record+read (zero signals) ==="
SID="ce2-$$"
node_record "$SID" '[]' >/dev/null
assert_eq "CE-2a. level read-back = low" 'low' "$(node_read_field "$SID" level | tr -d '\"')"
assert_eq "CE-2b. empty signals read-back = []" '[]' "$(node_read_field "$SID" signals)"

# ==========================================================================
# CE-3: hasComplexityEvaluation → true after record
# ==========================================================================
echo ""
echo "=== CE-3: hasComplexityEvaluation → true after record ==="
SID="ce3-$$"
node_record "$SID" '["S1-multi-file"]' >/dev/null
assert_eq "CE-3. hasComplexityEvaluation true after record" 'true' "$(node_has "$SID")"

# ===========
# CE-3b: hasComplexityEvaluation → true after record (level=low)
# ===========
echo ""
echo "=== CE-3b: hasComplexityEvaluation → true after record (level=low) ==="
SID="ce3b-$$"
node_record "$SID" '[]' >/dev/null
assert_eq "CE-3b. hasComplexityEvaluation true after low record" 'true' "$(node_has "$SID")"

# ==========================================================================
# CE-4: hasComplexityEvaluation → false when state file absent (fail-open)
# ==========================================================================
echo ""
echo "=== CE-4: hasComplexityEvaluation → false (state absent, fail-open) ==="
SID="ce4-missing-$$"
assert_eq "CE-4. hasComplexityEvaluation false when state absent" 'false' "$(node_has "$SID")"

# ==========================================================================
# CE-5: readComplexityEvaluation → null when state file absent
# ==========================================================================
echo ""
echo "=== CE-5: readComplexityEvaluation → null (state absent) ==="
SID="ce5-missing-$$"
assert_eq "CE-5. readComplexityEvaluation null when state absent" 'null' "$(node_read_json "$SID")"

# ==========================================================================
# CE-6: retired 3-arg (sid, level, signals) form → throw (#2099 arity change)
# ==========================================================================
echo ""
echo "=== CE-6: legacy 3-arg record call → throw ==="
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
assert_eq "CE-6. caller-supplied level is rejected" 'THREW' "$CE6_OUT"

# ==========================================================================
# CE-7: object missing required fields → null (fail-open read)
# ==========================================================================
echo ""
echo "=== CE-7: complexity record missing required fields → null ==="
SID="ce7-$$"
# Injected through the real event store: assigning s.complexity_evaluation
# before writeState() is stripped as a projection key (#1733), so the old
# seeder here left NO record and this case passed on the missing-file path.
inject_ce_event "$SID" "{ signals: [] }"
assert_eq "CE-7a. the level-less record actually persists through the projection" \
  '{"levels":null,"signals":[]}' "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "CE-7. partial complexity record reads null" 'null' "$(node_read_json "$SID")"

# ==========================================================================
# CE-8: non-array signals — where the guard actually sits.
# Injected for real, this record never reaches readComplexityEvaluation as a
# non-array: the PROJECTION normalizes signals to [] first, so the read returns
# a valid high+[] record. That is the true contract, and asserting 'null' here
# (as the stripped-seeder version did) encoded an unreachable expectation.
# The resolver's own !Array.isArray guard is pinned directly, on a value that
# never passes through the projection, by feature-2099 derivation-cases.sh D-11.
# ==========================================================================
echo ""
echo "=== CE-8: non-array signals is normalized by the projection ==="
SID="ce8-$$"
inject_ce_event "$SID" "{ level: 'high', signals: 'S1-multi-file' }"
assert_eq "CE-8a. the projection normalizes a string signals value to []" \
  '{"level":"high","levels":null,"signals":[]}' "$(ce_projected "$SID" | sed 's/,"recorded_at":"[^"]*"//')"
assert_eq "CE-8b. the bogus token is not smuggled through as a signal" \
  '[]' "$(node_read_field "$SID" signals)"
assert_eq "CE-8. the read returns the normalized record, not null" \
  'high' "$(node_read_field "$SID" level | tr -d '\"')"

# ==========================================================================
# CE-9: double record → last-write-wins (idempotency)
# ==========================================================================
echo ""
echo "=== CE-9: double record → last-write-wins ==="
SID="ce9-$$"
node_record "$SID" '["S1-multi-file"]' >/dev/null
node_record "$SID" '[]' >/dev/null
assert_eq "CE-9a. level = last write (low)" 'low' "$(node_read_field "$SID" level | tr -d '\"')"
assert_eq "CE-9b. signals = last write ([])" '[]' "$(node_read_field "$SID" signals)"

# CE-9c/d: idempotency is a property of the PROJECTION ONLY. The event stream
# is append-only and appendEvents() does no dedup, coalescing, or rewriting of
# history, so repeating an IDENTICAL record deliberately appends another raw
# event — the audit trail must show that the judgement was made three times.
# Verified against the live module: 3 identical calls → 3 events, 1 folded
# record. Asserting "the count does not grow" here would pin the opposite of
# the real contract and would break the moment the audit history is used.
SID="ce9idem-$$"
node_record "$SID" '["S1-multi-file"]' >/dev/null
node_record "$SID" '["S1-multi-file"]' >/dev/null
node_record "$SID" '["S1-multi-file"]' >/dev/null
assert_eq "CE-9c. three identical records append three raw events (append-only audit history)" \
  '3' "$(ce_event_count "$SID")"
assert_eq "CE-9d. ...while the projection still folds to a single record" \
  '["S1-multi-file"]' "$(node_read_field "$SID" signals)"

# ==========================================================================
# C7 — schema edge cases (all S1-S6 present, duplicates, unknown, long, ISO)
# ==========================================================================
echo ""
echo "=== CE-SCHEMA-1: all S1..S6 signals round-trip ==="
SID="ceall-$$"
node_record "$SID" '["S1","S2","S3","S4","S5","S6"]' >/dev/null
assert_eq "CE-SCHEMA-1. all six signals preserved" '["S1","S2","S3","S4","S5","S6"]' "$(node_read_field "$SID" signals)"

echo ""
echo "=== CE-SCHEMA-2: duplicate signal ids preserved verbatim (no dedup) ==="
SID="cedup-$$"
node_record "$SID" '["S1","S1","S2"]' >/dev/null
assert_eq "CE-SCHEMA-2. duplicates stored as-is" '["S1","S1","S2"]' "$(node_read_field "$SID" signals)"

echo ""
echo "=== CE-SCHEMA-3: unknown signal name stored (no value validation) ==="
SID="ceunk-$$"
node_record "$SID" '["unknown-signal"]' >/dev/null
assert_eq "CE-SCHEMA-3. unknown signal accepted" '["unknown-signal"]' "$(node_read_field "$SID" signals)"

echo ""
echo "=== CE-SCHEMA-4: very long signal string stored intact ==="
SID="celong-$$"
LONG="$(printf 'S%.0s' $(seq 1 300))"
node_record "$SID" "[\"$LONG\"]" >/dev/null
assert_eq "CE-SCHEMA-4. long signal preserved" "[\"$LONG\"]" "$(node_read_field "$SID" signals)"

echo ""
echo "=== CE-SCHEMA-5: recorded_at is ISO 8601 ==="
SID="ceiso-$$"
node_record "$SID" '["S1"]' >/dev/null
ISO_VAL="$(node_read_field "$SID" recorded_at | tr -d '\"')"
if printf '%s' "$ISO_VAL" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
  pass "CE-SCHEMA-5. recorded_at ISO 8601 [$ISO_VAL]"
else
  fail "CE-SCHEMA-5. recorded_at not ISO 8601 -- got [$ISO_VAL]"
fi

# ==========================================================================
# C8 — corrupt JSON / type errors (direct state-file manipulation)
# ==========================================================================
echo ""
echo "=== CE-CORRUPT-1: malformed JSON state file → null (fail-open) ==="
SID="cecorrupt-$$"
write_raw_state "$SID" '{invalid json'
assert_eq "CE-CORRUPT-1. malformed JSON reads null" 'null' "$(node_read_json "$SID")"

echo ""
echo "=== CE-CORRUPT-2: complexity_evaluation is a string → null ==="
SID="cestr-$$"
write_raw_state "$SID" '{"session_id":"cestr","complexity_evaluation":"opus"}'
assert_eq "CE-CORRUPT-2. string complexity_evaluation reads null" 'null' "$(node_read_json "$SID")"

echo ""
echo "=== CE-CORRUPT-3: recorded_at missing → null (fail-open) ==="
SID="cenorec-$$"
write_raw_state "$SID" '{"session_id":"cenorec","complexity_evaluation":{"level":"high","signals":["S1"]}}'
assert_eq "CE-CORRUPT-3. missing recorded_at reads null" 'null' "$(node_read_json "$SID")"

echo ""
echo "=== CE-CORRUPT-4: non-string signal element still stored (no element validation) ==="
SID="ceelem-$$"
# signals is a valid array; element-level type is NOT validated by the read API.
write_raw_state "$SID" '{"session_id":"ceelem","complexity_evaluation":{"level":"high","signals":[1,2],"recorded_at":"2026-07-11T00:00:00.000Z"}}'
RES="$(node_read_json "$SID")"
check_not_contains "CE-CORRUPT-4. array-of-numbers signals NOT rejected as null" "null" "$RES"
