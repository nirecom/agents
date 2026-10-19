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
# Pin here: the checker does not credit common.sh's pin to this file; common.sh re-pins under GT_BASE.
harness_isolate
# shellcheck source=feat-2490-next-step-gate/common.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2490-next-step-gate/common.sh"

# ERROR fixtures, the same two shapes value-line.sh uses (#2681: the gate resolves in-process,
# so bin/ stubs are never read): no hooks/lib/config-flag.js, and a load-env whose CONFIRM_*
# lookups throw (the original stays as load-env-real.js so the rest of next-step still loads).
CFG_NOLIB="$GT_BASE/cfg-nolib"; mk_tree "$CFG_NOLIB"; rm -f "$CFG_NOLIB/hooks/lib/config-flag.js"
CFG_THROW="$GT_BASE/cfg-throw"; mk_tree "$CFG_THROW"
mv "$CFG_THROW/hooks/lib/load-env.js" "$CFG_THROW/hooks/lib/load-env-real.js"
printf '"use strict";\nconst real = require("./load-env-real");\nmodule.exports = Object.assign({}, real, { resolveConfigVar: function (n, d, o) { if (/^CONFIRM_/.test(n)) throw new Error("stub: resolveConfigVar throws"); return real.resolveConfigVar(n, d, o); } });\n' > "$CFG_THROW/hooks/lib/load-env.js"
line_n() { printf '%s\n' "$OUT" | sed -n "$1p"; }

echo "=== (C1) seven gates x ON / OFF / ERROR ==="
case_begin "seven-gates-on-off-error-matrix" "bin/workflow/lib/next-step/gate-line.js"
for step in $GATE_STEPS; do
  key="$(gate_key_of "$step")"; sid="mx-$step"
  write_state "$sid" "$(json_at "$step")"
  # detail reads the intent for scope-change; clarify_intent is blocked (closes_issues-empty)
  # before any value line unless the intent names an issue.
  case "$step" in
    detail) put_plan "$sid" intent "$INTENT_FULL" ;;
    clarify_intent) put_plan "$sid" intent "$(printf '%s\n\n## Issues\n\n- #2490\n' "$INTENT_FULL")" ;;
  esac
  for row in off:OFF on:ON; do
    export "$key=${row%%:*}"
    ns --session "$sid"
    check "$step $key=${row%%:*}: ACTION=invoke" "invoke" "$(val ACTION)"
    check "$step $key=${row%%:*}: exactly one value line" 1 "$(count_re "$OUT" '^GATE_CONFIRM_')"
    check "$step $key=${row%%:*}: value line is last" "GATE_$key=${row#*:}" "$(last_line "$OUT")"
  done
  export "$key=on"
  for cfg in "$CFG_NOLIB" "$CFG_THROW"; do
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
  # #2277: completing clarify_intent requires an approval bound to the intent artifact.
  [ "$from" = "clarify_intent" ] && node "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-approval-fixture.js" approve "$sid" clarify_intent >/dev/null 2>&1
  ns --session "$sid" --advance --step "$from" --complete --next
  check "$from->$to: exit 0" 0 "$RC"
  check "$from->$to: verdict block starts with ACTION=invoke" "ACTION=invoke" "$(line_n 3)"
  check "$from->$to: REASON names the new step" "$to" "$(unq "$(val REASON)")"
  check "$from->$to: no GATE_CONFIRM_ line" 0 "$(count_re "$OUT" '^GATE_CONFIRM_')"
done
case_end

gt_finish
