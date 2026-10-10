#!/usr/bin/env bash
# tests/bin/feat-2490-next-step-value-line-matrix.sh
# Tests: bin/workflow/lib/next-step/gate-line.js, bin/workflow/lib/next-step/verdict.js
# Tags: tl2, workflow, confirm-gate, next-step, value-line, advance, scope:issue-specific, pwsh-not-required
# #2490 (a): GATE_CONFIRM_<X> for all seven gates x ON/OFF/ERROR, and on the --advance --next path.

# TL3 gap (what this test does NOT catch): whether a live model reads the value line
# as display-only after --advance --next. Closest-to-action mitigation:
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=feat-2490-next-step-gate/common.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2490-next-step-gate/common.sh"

# ERROR fixtures, same two shapes value-line.sh uses: get-config-var exits 4, no confirm-off.
CFG_E4="$GT_BASE/cfg-e4"; mk_tree "$CFG_E4"; printf '#!/usr/bin/env bash\nexit 4\n' > "$CFG_E4/bin/get-config-var"
CFG_NOCO="$GT_BASE/cfg-noco"; mk_tree "$CFG_NOCO"; rm -f "$CFG_NOCO/bin/confirm-off" "$CFG_NOCO/bin/get-config-var"
line_n() { printf '%s\n' "$OUT" | sed -n "$1p"; }

echo "=== (C1) seven gates x ON / OFF / ERROR ==="
case_begin "seven-gates-on-off-error-matrix" "bin/workflow/lib/next-step/gate-line.js"
for step in $GATE_STEPS; do
  key="$(gate_key_of "$step")"; sid="mx-$step"
  write_state "$sid" "$(json_at "$step")"
  [ "$step" = "detail" ] && put_plan "$sid" intent "$INTENT_FULL"
  for row in off:OFF on:ON; do
    export "$key=${row%%:*}"
    ns --session "$sid"
    check "$step $key=${row%%:*}: ACTION=invoke" "invoke" "$(val ACTION)"
    check "$step $key=${row%%:*}: exactly one value line" 1 "$(count_re "$OUT" '^GATE_CONFIRM_')"
    check "$step $key=${row%%:*}: value line is last" "GATE_$key=${row#*:}" "$(last_line "$OUT")"
  done
  export "$key=on"
  for cfg in "$CFG_E4" "$CFG_NOCO"; do
    OUT="$(run_next_step_in "$cfg" --session "$sid" 2>/dev/null || true)"
    check "$step ${cfg##*/}: value line ERROR" "GATE_$key=ERROR" "$(last_line "$OUT")"
    check "$step ${cfg##*/}: ACTION still invoke" "invoke" "$(val ACTION)"
  done
done
pin_confirm on
case_end

echo "=== (C2) --advance --next lands on the next step and carries its value line ==="
case_begin "advance-next-gate-step-value-line" "bin/workflow/lib/next-step/verdict.js"
for row in "research|outline" "branching_complete|write_tests" "review_security|docs"; do
  from="${row%%|*}"; to="${row#*|}"; key="$(gate_key_of "$to")"
  for v in off:OFF on:ON; do
    sid="mx-adv-$from-${v%%:*}"
    write_state "$sid" "$(json_at "$from")"
    put_plan "$sid" intent "$INTENT_FULL"
    export "$key=${v%%:*}"
    ns --session "$sid" --advance --step "$from" --complete --next
    check "$from->$to ${v%%:*}: exit 0" 0 "$RC"
    check "$from->$to ${v%%:*}: line 1 ADVANCED" "ADVANCED=$from status=complete" "$(line_n 1)"
    check "$from->$to ${v%%:*}: line 2 ADVANCE_SCOPE" "ADVANCE_SCOPE=current-step" "$(line_n 2)"
    check "$from->$to ${v%%:*}: verdict block starts with ACTION=invoke" "ACTION=invoke" "$(line_n 3)"
    check "$from->$to ${v%%:*}: REASON names the new step" "$to" "$(unq "$(val REASON)")"
    check "$from->$to ${v%%:*}: exactly one value line" 1 "$(count_re "$OUT" '^GATE_CONFIRM_')"
    check "$from->$to ${v%%:*}: value line of the new step, last" "GATE_$key=${v#*:}" "$(last_line "$OUT")"
  done
  export "$key=on"
done
case_end

case_begin "advance-next-non-gate-step-no-value-line" "bin/workflow/lib/next-step/verdict.js"
for row in "clarify_intent|research" "run_tests|review_security"; do
  from="${row%%|*}"; to="${row#*|}"; sid="mx-adv-ng-$from"
  write_state "$sid" "$(json_at "$from")"
  put_plan "$sid" intent "$INTENT_FULL"
  ns --session "$sid" --advance --step "$from" --complete --next
  check "$from->$to: exit 0" 0 "$RC"
  check "$from->$to: verdict block starts with ACTION=invoke" "ACTION=invoke" "$(line_n 3)"
  check "$from->$to: REASON names the new step" "$to" "$(unq "$(val REASON)")"
  check "$from->$to: no GATE_CONFIRM_ line" 0 "$(count_re "$OUT" '^GATE_CONFIRM_')"
done
case_end

gt_finish
