#!/bin/bash
# shellcheck shell=bash
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: L2, workflow, skip-signal, next-step, scope:issue-specific
# feature-1286 next-step cases: bin/workflow/next-step marks a planning step
# skipped when a valid recorded judgment exists and advances the verdict.
# Relies on helpers.sh being sourced by the dispatcher.

# #2277: approve the complete gated steps after plant_valid_skip, which truncates the artifact the sha binds.
approve_gated() {
  run_with_timeout node "$SCRIPT_CHECKOUT_ROOT_N/tests/lib/plan-approval-fixture.js" inject-complete \
    "$WORKFLOW_DIR_N/$1.json" clarify_intent outline detail >/dev/null 2>&1 || echo "APPROVE_ERR:$1"
}

run_next() {
  local sid="$1"
  approve_gated "$sid"
  WORKFLOW_STATE_DIR="$WORKFLOW_DIR" run_with_timeout node "$NEXT_STEP" --session "$sid" 2>/dev/null || echo "ERROR"
}

# embed_skip_judgment <base-json> <step> <source> <conditions-js-literal>
# Prints <base-json> with a fully-formed skip_judgment on <step>.
embed_skip_judgment() {
  printf '%s' "$1" | node -e "
    let d=''; process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      const s=JSON.parse(d);
      s.steps['$2'].skip_judgment={
        recorded_at:'2099-01-01T00:00:00.000Z',
        judgment_source:'$3',
        conditions:$4,
        all_conditions_met:true
      };
      console.log(JSON.stringify(s));
    });
  "
}

# hvsj_sanity <label> <sid> <target>: the skip branch must really be entered,
# otherwise a count of 0/1 below would be a false green.
hvsj_sanity() {
  local label="$1" sid="$2" target="$3" got
  got="$(WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" node -e "
    const r = require('$RESOLVER_N');
    if (typeof r.hasValidSkipJudgment !== 'function') { console.log('NOT_FUNCTION'); process.exit(0); }
    console.log(r.hasValidSkipJudgment('$sid', '$target') ? 'TRUE' : 'FALSE');
  " 2>&1)"
  check "$label sanity: hasValidSkipJudgment is TRUE for the $sid $target fixture" "TRUE" "$got"
}

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-10: valid outline record → outline skipped, next step is detail ==="
write_state "rv10" "$JSON_AT_OUTLINE"
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv10" "outline" "{ so_c1: true, so_c2: true }"
OUT="$(run_next rv10)"
check_contains "RV-10a: outline skipped → next step is detail" "NEXT_SKILL=make-detail-plan" "$OUT"
check_not_contains "RV-10b: outline skipped → not pointing at make-outline-plan" "NEXT_SKILL=make-outline-plan" "$OUT"
STATUS="$(read_state_field rv10 outline status)"
check "RV-10c: outline step status is skipped in state" '"skipped"' "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-11: both records → both skipped → branching_complete ==="
write_state "rv11" "$JSON_AT_OUTLINE"
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv11" "outline" "{ so_c1: true, so_c2: true }"
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv11" "detail" "{ sd_single_approach: true, sd_no_open_decision: true }" "jev"
OUT="$(run_next rv11)"
check_not_contains "RV-11a: both skipped → not pointing at outline" "NEXT_SKILL=make-outline-plan" "$OUT"
check_not_contains "RV-11b: both skipped → not pointing at detail" "NEXT_SKILL=make-detail-plan" "$OUT"
check_contains "RV-11c: both skipped → REASON=branching_complete" "REASON='branching_complete'" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-16: idempotency — next-step twice → outline stays skipped, no corruption ==="
write_state "rv16" "$JSON_AT_OUTLINE"
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv16" "outline" "{ so_c1: true, so_c2: true }"
OUT1="$(run_next rv16)"
STATUS1="$(read_state_field rv16 outline status)"
OUT2="$(run_next rv16)"
STATUS2="$(read_state_field rv16 outline status)"
check "RV-16a: outline skipped after first next-step run" '"skipped"' "$STATUS1"
check "RV-16b: outline still skipped after second next-step run" '"skipped"' "$STATUS2"
check_contains "RV-16c: second run advances to detail (not outline)" "NEXT_SKILL=make-detail-plan" "$OUT2"
check_not_contains "RV-16d: second run not an abort" "ACTION=abort" "$OUT2"

# ---------------------------------------------------------------------------
# RV-REC-1: an EISDIR markStep failure in the outline skip block must not recurse into
# computeVerdict; hvsj-call-counter.js counts state tmp-write attempts (unfixed: >>1, fixed: 1).
# ---------------------------------------------------------------------------
HVSJ_COUNTER_PRELOAD_N="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-1286-recorded-verdict-skip/hvsj-call-counter.js" 2>/dev/null || echo "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-1286-recorded-verdict-skip/hvsj-call-counter.js")"
NEXT_STEP_N="$(cygpath -m "$NEXT_STEP" 2>/dev/null || echo "$NEXT_STEP")"

echo ""
echo "=== RV-REC-1: markStep failure in outline skip must not infinite-recurse ==="
: > "$PLANS_GLOBAL_DIR/rvrec1-intent.md"
write_state "rvrec1" "$(embed_skip_judgment "$JSON_AT_OUTLINE" outline subagent '{so_c1:true,so_c2:true}')"
approve_gated rvrec1
hvsj_sanity "RV-REC-1" rvrec1 outline
RVREC1_CTR_FILE="$WORKFLOW_DIR/rvrec1-write-counter.txt"
RVREC1_CTR_FILE_N="$(cygpath -m "$RVREC1_CTR_FILE" 2>/dev/null || echo "$RVREC1_CTR_FILE")"
RVREC1_OUT="$(HVSJ_COUNTER_FILE="$RVREC1_CTR_FILE_N" HVSJ_FAULT_SID="rvrec1" WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 20 node --require "$HVSJ_COUNTER_PRELOAD_N" "$NEXT_STEP_N" --session rvrec1 2>&1)"; RVREC1_RC=$?
RVREC1_CTR="$(cat "$RVREC1_CTR_FILE" 2>/dev/null || echo "0")"
check "RV-REC-1a: exit code is 0 (no timeout, no crash)" "0" "$RVREC1_RC"
check "RV-REC-1b: markStep attempted exactly once — no recursion (unfixed: >1)" "1" "$RVREC1_CTR"
check_contains "RV-REC-1c: fell through to normal outline handling — NEXT_SKILL=make-outline-plan" \
  "NEXT_SKILL=make-outline-plan" "$RVREC1_OUT"
check_not_contains "RV-REC-1d: must not have advanced past outline to detail" \
  "NEXT_SKILL=make-detail-plan" "$RVREC1_OUT"

# ---------------------------------------------------------------------------
# RV-35: the skip_judgment audit trail survives the outline skip unchanged.
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-35: skip_judgment audit field preserved after outline skip ==="
write_state "rv35" "$JSON_AT_OUTLINE"
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv35" "outline" "{ so_c1: true, so_c2: true }"
RV35_OUT="$(run_next rv35)"
RV35_AFTER="$(read_skip_judgment_raw rv35 outline)"
if [ "$RV35_AFTER" = "null" ]; then
  fail "RV-35a: skip_judgment removed from outline step after skip (should be preserved)"
else
  pass "RV-35a: skip_judgment present in outline step after skip"
fi
check_contains "RV-35b: stored skip_judgment.judgment_source=subagent" '"judgment_source":"subagent"' "$RV35_AFTER"
check_contains "RV-35c: stored skip_judgment.all_conditions_met=true" '"all_conditions_met":true' "$RV35_AFTER"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-REC-2: markStep failure in detail skip must not infinite-recurse ==="
: > "$PLANS_GLOBAL_DIR/rvrec2-outline.md"
write_state "rvrec2" "$(embed_skip_judgment "$JSON_AT_DETAIL" detail jev '{sd_single_approach:true,sd_no_open_decision:true}')"
approve_gated rvrec2
hvsj_sanity "RV-REC-2" rvrec2 detail
RVREC2_CTR_FILE="$WORKFLOW_DIR/rvrec2-write-counter.txt"
RVREC2_CTR_FILE_N="$(cygpath -m "$RVREC2_CTR_FILE" 2>/dev/null || echo "$RVREC2_CTR_FILE")"
RVREC2_OUT="$(HVSJ_COUNTER_FILE="$RVREC2_CTR_FILE_N" HVSJ_FAULT_SID="rvrec2" WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 20 node --require "$HVSJ_COUNTER_PRELOAD_N" "$NEXT_STEP_N" --session rvrec2 2>&1)"; RVREC2_RC=$?
RVREC2_CTR="$(cat "$RVREC2_CTR_FILE" 2>/dev/null || echo "0")"
check "RV-REC-2a: exit code is 0 (no timeout, no crash)" "0" "$RVREC2_RC"
check "RV-REC-2b: markStep attempted exactly once — no recursion (unfixed: >1)" "1" "$RVREC2_CTR"
check_contains "RV-REC-2c: fell through to normal detail handling — NEXT_SKILL=make-detail-plan" \
  "NEXT_SKILL=make-detail-plan" "$RVREC2_OUT"

# ---------------------------------------------------------------------------
# RV-36: applyRecordedVerdictSkip reads skip_judgment exactly once per outline skip.
# read-skip-judgment-counter.js (--require preload) wraps the resolver export and counts
# calls; 0 means the skip branch was never entered, >1 is a double-read race.
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-36: applyRecordedVerdictSkip reads skip_judgment exactly once ==="
RSJ_COUNTER_PRELOAD_N="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-1286-recorded-verdict-skip/read-skip-judgment-counter.js" 2>/dev/null || echo "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-1286-recorded-verdict-skip/read-skip-judgment-counter.js")"
: > "$PLANS_GLOBAL_DIR/rv36-intent.md"
write_state "rv36" "$(embed_skip_judgment "$JSON_AT_OUTLINE" outline mixed '{so_c1:true,so_c2:true}')"
approve_gated rv36
hvsj_sanity "RV-36" rv36 outline
RV36_CTR_FILE="$WORKFLOW_DIR/rv36-rsj-counter.txt"
RV36_CTR_FILE_N="$(cygpath -m "$RV36_CTR_FILE" 2>/dev/null || echo "$RV36_CTR_FILE")"
RV36_OUT="$(RSJ_COUNTER_FILE="$RV36_CTR_FILE_N" WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 20 node --require "$RSJ_COUNTER_PRELOAD_N" "$NEXT_STEP_N" --session rv36 2>&1)"; RV36_RC=$?
RV36_CTR="$(cat "$RV36_CTR_FILE" 2>/dev/null || echo "0")"
check "RV-36a: exit code is 0 (no timeout, no crash)" "0" "$RV36_RC"
check "RV-36b: readSkipJudgment called exactly once — no double-read race (unfixed or no-skip-branch: !=1)" "1" "$RV36_CTR"
check_contains "RV-36c: outline skipped → NEXT_SKILL=make-detail-plan" "NEXT_SKILL=make-detail-plan" "$RV36_OUT"
