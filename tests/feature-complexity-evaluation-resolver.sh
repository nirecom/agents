#!/bin/bash
# Tests: hooks/lib/workflow-state/skip-signal-resolver.js, hooks/lib/workflow-state/state-io.js, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation
# Tags: L2, workflow, complexity-evaluation, scope:issue-specific
#
# Issue #1350 — one-time persisted SSOT for the S1..S6 complexity evaluation.
#
# recordComplexityEvaluation(sessionId, verdict, signals) persists a single
# complexity verdict into workflow state (createInitialState seeds the slot);
# readComplexityEvaluation / hasComplexityEvaluation are read-only accessors on
# skip-signal-resolver.js and fail-open (missing/invalid → null / false).
#
# CLIs bin/workflow/{record,read}-complexity-evaluation wrap the write/read APIs
# for SKILL.md Bash calls.
#
# Pre-implementation model: the write/read APIs and CLIs may not yet exist. This
# suite does NOT exit 77 globally. Instead it probes API/CLI presence once, sets
# API_READY / CLI_READY, and SKIPs individual cases (incrementing SKIP, not FAIL)
# when the target is absent. Result: exit 0 (all SKIP) before implementation, and
# real FAILs after implementation lands but misbehaves. SKIP never counts as FAIL.
#
# L3 gap (what this test does NOT catch):
# - Real orchestrator-driven single-write flow across CI-C1b / MDP-3 / WCD-3 /
#   WT-5 in a live claude -p session (this test drives the APIs/CLIs directly
#   with synthetic session state, not a real workflow run).
# Closest-to-action mitigation: static reader-ordering checks in the sibling
# feature-clarify-intent-complexity-write-static.sh / feature-1350-mdp-wt-reader-static.sh
# and the write-code-skill-static reader assertions.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

# Setup, presence probes, counters, and helpers live in the sibling lib
# (rules/coding/file-split.md Pattern A — entrypoint-private module).
# shellcheck source=tests/feature-complexity-evaluation-resolver/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/lib.sh"

# ==========================================================================
# CE-1: round-trip record+read (verdict=opus, signals non-empty)
# ==========================================================================
echo ""
echo "=== CE-1: round-trip record+read (opus, non-empty signals) ==="
if [ "$API_READY" = "true" ]; then
  SID="ce1-$$"
  node_record "$SID" "opus" '["S1-multi-file","S2-architecture"]' >/dev/null
  assert_eq "CE-1a. verdict read-back = opus" 'opus' "$(node_read_field "$SID" verdict | tr -d '\"')"
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
  node_record "$SID" "sonnet" '[]' >/dev/null
  assert_eq "CE-2a. verdict read-back = sonnet" 'sonnet' "$(node_read_field "$SID" verdict | tr -d '\"')"
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
  node_record "$SID" "opus" '["S1-multi-file"]' >/dev/null
  assert_eq "CE-3. hasComplexityEvaluation true after record" 'true' "$(node_has "$SID")"
else
  skip "CE-3 (API absent)"
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
  # Hand-craft a state file whose complexity_evaluation lacks the verdict field.
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
    s.complexity_evaluation = { verdict: 'opus', signals: 'S1-multi-file', recorded_at: new Date().toISOString() };
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
  node_record "$SID" "opus" '["S1-multi-file"]' >/dev/null
  node_record "$SID" "sonnet" '[]' >/dev/null
  assert_eq "CE-9a. verdict = last write (sonnet)" 'sonnet' "$(node_read_field "$SID" verdict | tr -d '\"')"
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
  node_record "$SID" "opus" '["S1","S2","S3","S4","S5","S6"]' >/dev/null
  assert_eq "CE-SCHEMA-1. all six signals preserved" '["S1","S2","S3","S4","S5","S6"]' "$(node_read_field "$SID" signals)"
else
  skip "CE-SCHEMA-1 (API absent)"
fi

echo ""
echo "=== CE-SCHEMA-2: duplicate signal ids preserved verbatim (no dedup) ==="
if [ "$API_READY" = "true" ]; then
  SID="cedup-$$"
  node_record "$SID" "opus" '["S1","S1","S2"]' >/dev/null
  assert_eq "CE-SCHEMA-2. duplicates stored as-is" '["S1","S1","S2"]' "$(node_read_field "$SID" signals)"
else
  skip "CE-SCHEMA-2 (API absent)"
fi

echo ""
echo "=== CE-SCHEMA-3: unknown signal name stored (no value validation) ==="
if [ "$API_READY" = "true" ]; then
  SID="ceunk-$$"
  node_record "$SID" "opus" '["unknown-signal"]' >/dev/null
  assert_eq "CE-SCHEMA-3. unknown signal accepted" '["unknown-signal"]' "$(node_read_field "$SID" signals)"
else
  skip "CE-SCHEMA-3 (API absent)"
fi

echo ""
echo "=== CE-SCHEMA-4: very long signal string stored intact ==="
if [ "$API_READY" = "true" ]; then
  SID="celong-$$"
  LONG="$(printf 'S%.0s' $(seq 1 300))"
  node_record "$SID" "sonnet" "[\"$LONG\"]" >/dev/null
  assert_eq "CE-SCHEMA-4. long signal preserved" "[\"$LONG\"]" "$(node_read_field "$SID" signals)"
else
  skip "CE-SCHEMA-4 (API absent)"
fi

echo ""
echo "=== CE-SCHEMA-5: recorded_at is ISO 8601 ==="
if [ "$API_READY" = "true" ]; then
  SID="ceiso-$$"
  node_record "$SID" "opus" '["S1"]' >/dev/null
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
  write_raw_state "$SID" '{"session_id":"cenorec","complexity_evaluation":{"verdict":"opus","signals":["S1"]}}'
  assert_eq "CE-CORRUPT-3. missing recorded_at reads null" 'null' "$(node_read_json "$SID")"
else
  skip "CE-CORRUPT-3 (API absent)"
fi

echo ""
echo "=== CE-CORRUPT-4: non-string signal element still stored (no element validation) ==="
if [ "$API_READY" = "true" ]; then
  SID="ceelem-$$"
  # signals is a valid array; element-level type is NOT validated by the read API.
  write_raw_state "$SID" '{"session_id":"ceelem","complexity_evaluation":{"verdict":"opus","signals":[1,2],"recorded_at":"2026-07-11T00:00:00.000Z"}}'
  RES="$(node_read_json "$SID")"
  check_not_contains "CE-CORRUPT-4. array-of-numbers signals NOT rejected as null" "null" "$RES"
else
  skip "CE-CORRUPT-4 (API absent)"
fi

# ==========================================================================
# CLI cases (CE-10..CE-12 + failure + security + idempotency). Guard on CLI
# presence via CLI_READY; absence → SKIP (not FAIL) so pre-impl stays green.
# ==========================================================================
echo ""
echo "=== CE-10..CE-12: record/read CLIs ==="
if [ "$CLI_READY" != "true" ]; then
  skip "CE-10..CE-12 record/read CLI absent"
  skip "CE-CLI-FAIL-1..2 record CLI absent"
  skip "CE-SEC-1..5 record CLI absent"
  skip "CE-CLI-IDEMP-1 record/read CLI absent"
else
  # CE-10: CLI record + CLI read round-trip (opus, signals present).
  SID="ce10-$$"
  CE10_RC=0
  CE10_REC="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
    --session "$SID" --verdict opus --signals "S1-multi-file,S2-architecture" 2>/dev/null)" || CE10_RC=$?
  assert_eq "CE-10a. record CLI exit 0" '0' "$CE10_RC"
  check_contains "CE-10b. record CLI stdout RECORDED_COMPLEXITY verdict=opus" "RECORDED_COMPLEXITY verdict=opus" "$CE10_REC"
  # state file created under CLAUDE_WORKFLOW_DIR
  if [ -f "$WORKFLOW_DIR/${SID}.json" ]; then
    pass "CE-10c. state file created under CLAUDE_WORKFLOW_DIR"
  else
    fail "CE-10c. state file NOT created under CLAUDE_WORKFLOW_DIR"
  fi
  CE10R_RC=0
  CE10_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" --session "$SID" 2>/dev/null)" || CE10R_RC=$?
  assert_eq "CE-10d. read CLI exit 0" '0' "$CE10R_RC"
  check_contains "CE-10e. CLI read reports verdict opus" "verdict=opus" "$CE10_OUT"
  check_contains "CE-10f. CLI read reports signal S1-multi-file" "S1-multi-file" "$CE10_OUT"

  # CE-11: CLI read with no state → NONE (exit 0, not a crash).
  SID="ce11-missing-$$"
  CE11_RC=0
  CE11_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" --session "$SID" 2>/dev/null)" || CE11_RC=$?
  assert_eq "CE-11a. read CLI (no state) exit 0" '0' "$CE11_RC"
  check_contains "CE-11b. CLI read (no state) prints NONE" "NONE" "$CE11_OUT"

  # CE-12: CLI read-back hardening — record then read, verdict matches exactly.
  SID="ce12-$$"
  CE12_RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
    --session "$SID" --verdict sonnet --signals "" >/dev/null 2>&1 || CE12_RC=$?
  assert_eq "CE-12a. record CLI (empty signals) exit 0" '0' "$CE12_RC"
  CE12_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" --session "$SID" 2>/dev/null)"
  check_contains "CE-12b. CLI read-back verdict=sonnet" "verdict=sonnet" "$CE12_OUT"

  # ------------------------------------------------------------------
  # C2 — CLI failure verdicts (bad args must exit non-zero)
  # ------------------------------------------------------------------
  echo ""
  echo "=== CE-CLI-FAIL: invalid CLI args → exit 1 ==="
  CEF1_RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
    --session "cef1-$$" --verdict invalid >/dev/null 2>&1 || CEF1_RC=$?
  assert_eq "CE-CLI-FAIL-1. invalid verdict → exit 1" '1' "$CEF1_RC"

  CEF2_RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
    --session "" --verdict opus >/dev/null 2>&1 || CEF2_RC=$?
  assert_eq "CE-CLI-FAIL-2. empty session id → exit 1" '1' "$CEF2_RC"

  CEF3_RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
    --verdict opus >/dev/null 2>&1 || CEF3_RC=$?
  assert_eq "CE-CLI-FAIL-3. missing --session → exit 1" '1' "$CEF3_RC"

  # ------------------------------------------------------------------
  # C3 — security / injection on --session (must reject, no stray file)
  # sessionId contract: /^[A-Za-z0-9_-]+$/
  # ------------------------------------------------------------------
  echo ""
  echo "=== CE-SEC: malicious --session values rejected ==="
  # Pre-seed a canary file outside the reject set to prove no traversal write.
  CANARY="$TMPDIR_BASE/canary-evil"
  printf 'ORIGINAL' > "$CANARY"

  sec_reject() {
    local desc="$1" sid="$2"
    local rc=0
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
      --session "$sid" --verdict opus --signals "S1" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      pass "$desc (exit $rc)"
    else
      fail "$desc -- expected non-zero exit, got 0"
    fi
  }
  sec_reject "CE-SEC-1. path traversal ../evil rejected"       "../evil"
  sec_reject "CE-SEC-2. path separator foo/bar rejected"        "foo/bar"
  sec_reject "CE-SEC-3. shell metachar foo;bar rejected"        "foo;bar"
  sec_reject "CE-SEC-4. empty string rejected"                  ""
  LONGID="$(printf 'a%.0s' $(seq 1 200))/x"
  sec_reject "CE-SEC-5. long id with separator rejected"        "$LONGID"

  # Traversal target must not have been created/overwritten.
  if [ "$(cat "$CANARY" 2>/dev/null)" = "ORIGINAL" ]; then
    pass "CE-SEC-6. canary file untouched by traversal attempts"
  else
    fail "CE-SEC-6. canary file was modified — traversal not contained"
  fi
  # And no file materialized above the workflow dir via ../evil.
  if [ -f "$WORKFLOW_DIR/../evil.json" ]; then
    fail "CE-SEC-7. ../evil.json created outside workflow dir"
    rm -f "$WORKFLOW_DIR/../evil.json"
  else
    pass "CE-SEC-7. no ../evil.json created outside workflow dir"
  fi

  # ------------------------------------------------------------------
  # C9 — CLI-level idempotency (double record, same verdict)
  # ------------------------------------------------------------------
  echo ""
  echo "=== CE-CLI-IDEMP: double CLI record, same verdict ==="
  SID="ceidemp-$$"
  I1_RC=0; I2_RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
    --session "$SID" --verdict opus --signals "S1" >/dev/null 2>&1 || I1_RC=$?
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
    --session "$SID" --verdict opus --signals "S1" >/dev/null 2>&1 || I2_RC=$?
  assert_eq "CE-CLI-IDEMP-1a. first record exit 0" '0' "$I1_RC"
  assert_eq "CE-CLI-IDEMP-1b. second record exit 0 (idempotent)" '0' "$I2_RC"
  IDEMP_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" --session "$SID" 2>/dev/null)"
  check_contains "CE-CLI-IDEMP-1c. read still verdict=opus" "verdict=opus" "$IDEMP_OUT"
  # Exactly one state file (no duplication).
  N_FILES="$(ls -1 "$WORKFLOW_DIR/${SID}.json" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "CE-CLI-IDEMP-1d. exactly one state file" '1' "$N_FILES"
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
