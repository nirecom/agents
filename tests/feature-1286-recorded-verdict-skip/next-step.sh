#!/bin/bash
# shellcheck shell=bash
# feature-1286 next-step cases: bin/workflow/next-step marks a planning step
# skipped when a valid recorded judgment exists and advances the verdict.
# Relies on helpers.sh being sourced by the dispatcher.

plant_record() {
  local sid="$1" target="$2" cond="$3"
  api_exists || return 0
  run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    r.recordSkipJudgment('$sid', '$target', $cond, 'orchestrator');
  " 2>/dev/null || true
}

run_next() {
  local sid="$1"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$NEXT_STEP" --session "$sid" 2>/dev/null || echo "ERROR"
}

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-10: valid outline record → outline skipped, next step is detail ==="
write_state "rv10" "$JSON_AT_OUTLINE"
plant_record "rv10" "outline" "{ so_c1: true, so_c2: true }"
OUT="$(run_next rv10)"
check_contains "RV-10a: outline skipped → next step is detail" "NEXT_SKILL=make-detail-plan" "$OUT"
check_not_contains "RV-10b: outline skipped → not pointing at make-outline-plan" "NEXT_SKILL=make-outline-plan" "$OUT"
STATUS="$(read_state_field rv10 outline status)"
check "RV-10c: outline step status is skipped in state" '"skipped"' "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-11: both records → both skipped → branching_complete ==="
write_state "rv11" "$JSON_AT_OUTLINE"
plant_record "rv11" "outline" "{ so_c1: true, so_c2: true }"
plant_record "rv11" "detail" "{ sd_c1: true, sd_c2: true, sd_c3: true }"
OUT="$(run_next rv11)"
check_not_contains "RV-11a: both skipped → not pointing at outline" "NEXT_SKILL=make-outline-plan" "$OUT"
check_not_contains "RV-11b: both skipped → not pointing at detail" "NEXT_SKILL=make-detail-plan" "$OUT"
check_contains "RV-11c: both skipped → REASON=branching_complete" "REASON='branching_complete'" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-16: idempotency — next-step twice → outline stays skipped, no corruption ==="
write_state "rv16" "$JSON_AT_OUTLINE"
plant_record "rv16" "outline" "{ so_c1: true, so_c2: true }"
OUT1="$(run_next rv16)"
STATUS1="$(read_state_field rv16 outline status)"
OUT2="$(run_next rv16)"
STATUS2="$(read_state_field rv16 outline status)"
check "RV-16a: outline skipped after first next-step run" '"skipped"' "$STATUS1"
check "RV-16b: outline still skipped after second next-step run" '"skipped"' "$STATUS2"
check_contains "RV-16c: second run advances to detail (not outline)" "NEXT_SKILL=make-detail-plan" "$OUT2"
check_not_contains "RV-16d: second run not an abort" "ACTION=abort" "$OUT2"

# ---------------------------------------------------------------------------
# RV-REC-1: markStep persistence failure in outline skip block must NOT
# infinite-recurse.  Fault injection: create a directory at <sid>.json.tmp so
# writeFileSync throws EISDIR -> markStep throws -> the unfixed code's
# unconditional `return computeVerdict` recurses O(stack-depth) times before
# the RangeError is caught by the outer catch.  The fix moves the
# `return computeVerdict` call to inside the try block so it is only reached
# when markStep succeeds; on failure it falls through without recursing.
#
# Observable regression: the unfixed code attempts fs.writeFileSync to
# *.json.tmp thousands of times (each recursive computeVerdict call re-enters
# markStep), while the fixed code attempts it exactly once per invocation.
# The hvsj-call-counter.js preload counts *.json.tmp write attempts and writes
# the total to HVSJ_COUNTER_FILE on exit.  We assert count == 1.
#
# These cases FAIL on the unfixed code (count >> 1) and PASS after the fix
# (count == 1).
# ---------------------------------------------------------------------------
HVSJ_COUNTER_PRELOAD_N="$(cygpath -m "$AGENTS_DIR/tests/feature-1286-recorded-verdict-skip/hvsj-call-counter.js" 2>/dev/null || echo "$AGENTS_DIR/tests/feature-1286-recorded-verdict-skip/hvsj-call-counter.js")"
NEXT_STEP_N="$(cygpath -m "$NEXT_STEP" 2>/dev/null || echo "$NEXT_STEP")"

echo ""
echo "=== RV-REC-1: markStep failure in outline skip must not infinite-recurse ==="

# Build state with valid skip_judgment embedded directly in outline step.
# Using printf+write_state avoids calling recordSkipJudgment (which also uses
# .tmp) and keeps fixture writing independent of the fault injection target.
RVREC1_JSON="$(printf '%s' "$JSON_AT_OUTLINE" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    const s=JSON.parse(d);
    s.steps.outline.skip_judgment={
      recorded_at:'2026-01-01T00:00:00.000Z',
      judgment_source:'orchestrator',
      conditions:{so_c1:true,so_c2:true},
      all_conditions_met:true
    };
    console.log(JSON.stringify(s));
  });
")"
write_state "rvrec1" "$RVREC1_JSON"

# Sanity-guard: verify hasValidSkipJudgment returns true for this fixture so
# we know the skip branch is actually entered (false → test would never hit
# the buggy path, giving a false-green).
HVSJ_CHECK="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" node -e "
  const r = require('$RESOLVER_N');
  if (typeof r.hasValidSkipJudgment !== 'function') { console.log('NOT_FUNCTION'); process.exit(0); }
  const result = r.hasValidSkipJudgment('rvrec1', 'outline');
  console.log(result ? 'TRUE' : 'FALSE');
" 2>&1)"
if [ "$HVSJ_CHECK" = "NOT_FUNCTION" ]; then
  fail "RV-REC-1 sanity: hasValidSkipJudgment is not a function in resolver — skip branch will never be entered"
elif [ "$HVSJ_CHECK" != "TRUE" ]; then
  fail "RV-REC-1 sanity: hasValidSkipJudgment returned [$HVSJ_CHECK] for rvrec1/outline fixture — expected TRUE; skip branch will not be entered"
else
  pass "RV-REC-1 sanity: hasValidSkipJudgment is TRUE for rvrec1 outline fixture"
fi

# Fault injection: create a DIRECTORY at the .tmp path so writeFileSync throws EISDIR.
RVREC1_TMP_DIR="$WORKFLOW_DIR/rvrec1.json.tmp"
mkdir -p "$RVREC1_TMP_DIR"

# Counter file: receives the *.json.tmp write-attempt count on process exit.
RVREC1_CTR_FILE="$WORKFLOW_DIR/rvrec1-write-counter.txt"
RVREC1_CTR_FILE_N="$(cygpath -m "$RVREC1_CTR_FILE" 2>/dev/null || echo "$RVREC1_CTR_FILE")"

# Run next-step with the counter preload.  The hard timeout (20 s) prevents a
# genuine hang from wedging the suite; a stack-overflow/crash exits in < 1 s.
RVREC1_OUT="$(HVSJ_COUNTER_FILE="$RVREC1_CTR_FILE_N" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" bash "$AGENTS_DIR/bin/run-with-timeout.sh" 20 node --require "$HVSJ_COUNTER_PRELOAD_N" "$NEXT_STEP_N" --session rvrec1 2>&1)"; RVREC1_RC=$?

# Read write-attempt count (default 0 if file missing).
RVREC1_CTR="$(cat "$RVREC1_CTR_FILE" 2>/dev/null || echo "0")"

# RV-REC-1a: no timeout — exit code must be 0 (not 124 timeout, not a crash).
check "RV-REC-1a: exit code is 0 (no timeout, no crash)" "0" "$RVREC1_RC"

# RV-REC-1b: the fix eliminates the unconditional recursion so markStep is
# attempted exactly once.  Unfixed code: thousands of attempts.
check "RV-REC-1b: markStep attempted exactly once — no recursion (unfixed: >1)" "1" "$RVREC1_CTR"

# RV-REC-1c: output still valid — fell through to normal outline handling.
check_contains "RV-REC-1c: fell through to normal outline handling — NEXT_SKILL=make-outline-plan" \
  "NEXT_SKILL=make-outline-plan" "$RVREC1_OUT"

# RV-REC-1d: must not have advanced past outline to detail.
check_not_contains "RV-REC-1d: must not have advanced past outline to detail" \
  "NEXT_SKILL=make-detail-plan" "$RVREC1_OUT"

# Clean up injected fault so it cannot affect later cases.
rm -rf "$RVREC1_TMP_DIR"

# ---------------------------------------------------------------------------
# RV-REC-2: same defect in the detail skip block.
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-REC-2: markStep failure in detail skip must not infinite-recurse ==="

RVREC2_JSON="$(printf '%s' "$JSON_AT_DETAIL" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    const s=JSON.parse(d);
    s.steps.detail.skip_judgment={
      recorded_at:'2026-01-01T00:00:00.000Z',
      judgment_source:'orchestrator',
      conditions:{sd_c1:true,sd_c2:true,sd_c3:true},
      all_conditions_met:true
    };
    console.log(JSON.stringify(s));
  });
")"
write_state "rvrec2" "$RVREC2_JSON"

# Sanity-guard for the detail fixture.
HVSJ_CHECK2="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" node -e "
  const r = require('$RESOLVER_N');
  if (typeof r.hasValidSkipJudgment !== 'function') { console.log('NOT_FUNCTION'); process.exit(0); }
  const result = r.hasValidSkipJudgment('rvrec2', 'detail');
  console.log(result ? 'TRUE' : 'FALSE');
" 2>&1)"
if [ "$HVSJ_CHECK2" = "NOT_FUNCTION" ]; then
  fail "RV-REC-2 sanity: hasValidSkipJudgment is not a function in resolver"
elif [ "$HVSJ_CHECK2" != "TRUE" ]; then
  fail "RV-REC-2 sanity: hasValidSkipJudgment returned [$HVSJ_CHECK2] for rvrec2/detail fixture — expected TRUE"
else
  pass "RV-REC-2 sanity: hasValidSkipJudgment is TRUE for rvrec2 detail fixture"
fi

# Fault injection for detail .tmp path.
RVREC2_TMP_DIR="$WORKFLOW_DIR/rvrec2.json.tmp"
mkdir -p "$RVREC2_TMP_DIR"

RVREC2_CTR_FILE="$WORKFLOW_DIR/rvrec2-write-counter.txt"
RVREC2_CTR_FILE_N="$(cygpath -m "$RVREC2_CTR_FILE" 2>/dev/null || echo "$RVREC2_CTR_FILE")"

RVREC2_OUT="$(HVSJ_COUNTER_FILE="$RVREC2_CTR_FILE_N" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" bash "$AGENTS_DIR/bin/run-with-timeout.sh" 20 node --require "$HVSJ_COUNTER_PRELOAD_N" "$NEXT_STEP_N" --session rvrec2 2>&1)"; RVREC2_RC=$?

RVREC2_CTR="$(cat "$RVREC2_CTR_FILE" 2>/dev/null || echo "0")"

check "RV-REC-2a: exit code is 0 (no timeout, no crash)" "0" "$RVREC2_RC"
check "RV-REC-2b: markStep attempted exactly once — no recursion (unfixed: >1)" "1" "$RVREC2_CTR"
check_contains "RV-REC-2c: fell through to normal detail handling — NEXT_SKILL=make-detail-plan" \
  "NEXT_SKILL=make-detail-plan" "$RVREC2_OUT"

rm -rf "$RVREC2_TMP_DIR"
