#!/bin/bash
# shellcheck shell=bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, skip-signal, next-step, error-cases, scope:issue-specific
# feature-1286 / #2460 end state: retired skip_judgment shapes (source=orchestrator,
# detail keys sd_c1..sd_c3) no longer skip a step, and the new-form
# record-skip-judgment --advance settles the step with the schema-derived reason.
# Relies on helpers.sh and next-step.sh (run_next, embed_skip_judgment) being sourced.

T_RS="0123456789abcdef"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-50: source=orchestrator outline record → outline runs ==="
write_state "rv50" "$JSON_AT_OUTLINE"
: > "$PLANS_GLOBAL_DIR/rv50-intent.md"
write_state "rv50" "$(embed_skip_judgment "$JSON_AT_OUTLINE" outline orchestrator '{so_c1:true,so_c2:true}')"
OUT="$(run_next rv50)"
check_contains "RV-50a: retired-source outline record → NEXT_SKILL=make-outline-plan" "NEXT_SKILL=make-outline-plan" "$OUT"
check_not_contains "RV-50b: retired-source outline record → not advanced to detail" "NEXT_SKILL=make-detail-plan" "$OUT"
check "RV-50c: outline stays pending" '"pending"' "$(read_state_field rv50 outline status)"

# Positive control on the same fixture shape: only the source differs.
: > "$PLANS_GLOBAL_DIR/rv50p-intent.md"
write_state "rv50p" "$(embed_skip_judgment "$JSON_AT_OUTLINE" outline jev '{so_c1:true,so_c2:true}')"
OUT="$(run_next rv50p)"
check_contains "RV-50d: control — jev outline record → NEXT_SKILL=make-detail-plan" "NEXT_SKILL=make-detail-plan" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-51: retired detail keys (sd_c1..sd_c3) → detail runs ==="
while IFS='|' read -r r_sid r_src r_cond r_label; do
  [ -z "$r_sid" ] && continue
  : > "$PLANS_GLOBAL_DIR/${r_sid}-outline.md"
  write_state "$r_sid" "$(embed_skip_judgment "$JSON_AT_DETAIL" detail "$r_src" "$r_cond")"
  OUT="$(run_next "$r_sid")"
  check_contains "RV-51 [$r_label] → NEXT_SKILL=make-detail-plan" "NEXT_SKILL=make-detail-plan" "$OUT"
  check "RV-51 [$r_label] → detail stays pending" '"pending"' "$(read_state_field "$r_sid" detail status)"
done <<'RETIRED'
rv51a|orchestrator|{sd_c1:true,sd_c2:true,sd_c3:true}|retired form orchestrator + sd_c1..c3
rv51b|jev|{sd_c1:true,sd_c2:true,sd_c3:true}|jev + retired keys
rv51c|orchestrator|{sd_single_approach:true,sd_no_open_decision:true}|orchestrator + new keys
RETIRED
: > "$PLANS_GLOBAL_DIR/rv51p-outline.md"
write_state "rv51p" "$(embed_skip_judgment "$JSON_AT_DETAIL" detail subagent '{sd_single_approach:true,sd_no_open_decision:true}')"
OUT="$(run_next rv51p)"
check_not_contains "RV-51d: control — subagent + new keys → detail skipped" "NEXT_SKILL=make-detail-plan" "$OUT"
check "RV-51d: control — detail is skipped" '"skipped"' "$(read_state_field rv51p detail status)"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-52: new-form --advance settles the step with the schema-derived reason ==="
while IFS='|' read -r a_sid a_target a_conds a_reason a_next; do
  [ -z "$a_sid" ] && continue
  if [ "$a_target" = "outline" ]; then
    write_state "$a_sid" "$JSON_AT_OUTLINE"; : > "$PLANS_GLOBAL_DIR/${a_sid}-intent.md"
  else
    write_state "$a_sid" "$JSON_AT_DETAIL"; : > "$PLANS_GLOBAL_DIR/${a_sid}-outline.md"
  fi
  ticketed "$a_sid" "$a_target" "$T_RS" "$(conds_json "$a_conds")" jev
  # shellcheck disable=SC2086 # a_conds is a deliberate word-split --cond list
  A_RC=0
  A_OUT="$(run_with_timeout node "$RECORD_CLI_N" --session "$a_sid" --target "$a_target" \
    $a_conds --source jev --ticket "$T_RS" --advance 2>&1)" || A_RC=$?
  check "RV-52 [$a_target]: --advance exits 0" "0" "$A_RC"
  check_contains "RV-52 [$a_target]: RECORDED= line kept" "RECORDED=$a_target all_conditions_met=true" "$A_OUT"
  check "RV-52 [$a_target]: step is skipped" '"skipped"' "$(read_state_field "$a_sid" "$a_target" status)"
  check "RV-52 [$a_target]: skip_reason is schema-derived" "\"$a_reason\"" \
    "$(read_state_field "$a_sid" "$a_target" skip_reason)"
  OUT="$(run_next "$a_sid")"
  check_not_contains "RV-52 [$a_target]: next-step is not blocked by the A-4 gate" "ACTION=blocked" "$OUT"
  check_contains "RV-52 [$a_target]: next-step moves past the step" "$a_next" "$OUT"
done <<'ADVANCE'
rv52o|outline|--cond so_c1=true --cond so_c2=true|recorded-verdict: so_c1+so_c2 met|NEXT_SKILL=make-detail-plan
rv52d|detail|--cond sd_single_approach=true --cond sd_no_open_decision=true|recorded-verdict: sd_single_approach+sd_no_open_decision met|REASON='branching_complete'
ADVANCE

echo ""
echo "=== RV-53: new-form --advance with a false condition leaves the step pending ==="
write_state "rv53" "$JSON_AT_DETAIL"; : > "$PLANS_GLOBAL_DIR/rv53-outline.md"
ticketed rv53 detail "$T_RS" '{"sd_single_approach":true,"sd_no_open_decision":false}' subagent
A_RC=0
A_OUT="$(run_with_timeout node "$RECORD_CLI_N" --session rv53 --target detail \
  --cond sd_single_approach=true --cond sd_no_open_decision=false --source subagent --ticket "$T_RS" --advance 2>&1)" || A_RC=$?
check "RV-53a: a false recording with --advance exits 0" "0" "$A_RC"
check_contains "RV-53b: RECORDED= line reports all_conditions_met=false" "RECORDED=detail all_conditions_met=false" "$A_OUT"
check "RV-53c: detail stays pending" '"pending"' "$(read_state_field rv53 detail status)"
check_contains "RV-53d: next-step routes to make-detail-plan" "NEXT_SKILL=make-detail-plan" "$(run_next rv53)"
