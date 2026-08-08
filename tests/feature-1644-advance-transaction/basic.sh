# shellcheck shell=bash
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/advance.js, bin/workflow/lib/next-step/state-ops.js
# Tags: tl2, workflow, next-step, advance, scope:issue-specific
# #1644 cases A1 / A5 / A11 / A12 / A13. Relies on helpers.sh being sourced first.

run_basic_cases() {
  echo ""
  echo "=== A1: --advance records; --next adds ADVANCED= + an ACTION block ==="
  at_research a1a
  run_ns --session a1a --advance --step research --status complete
  check "A1a: --advance alone exits 0" 0 "$NS_RC"
  check_contains "A1a: stdout carries ADVANCED=research status=complete" \
    "ADVANCED=research status=complete" "$NS_OUT"
  # `RECORDED=` belongs to record-skip-judgment's own judgment line (S1/S2) and
  # means something else there. The advance path must never mint a second,
  # differently-shaped `RECORDED=` on the same stdout.
  check_not_contains "A1a: the advance path emits no RECORDED= line" "RECORDED=" "$NS_OUT"
  check "A1a: projection shows research complete" '"complete"' "$(step_status a1a research)"
  check "A1a: --advance alone emits no ACTION line" 0 "$(action_line_count)"

  at_research a1b
  run_ns --session a1b --advance --step research --status complete --next
  check "A1b: --advance --next exits 0" 0 "$NS_RC"
  check_contains "A1b: stdout carries ADVANCED=research" "ADVANCED=research" "$NS_OUT"
  check "A1b: exactly one ACTION line" 1 "$(action_line_count)"
  check_contains "A1b: ACTION block names the next skill" "NEXT_SKILL=" "$NS_OUT"

  echo ""
  echo "=== A5: repeating the same --advance is idempotent (already=true) ==="
  at_research a5
  run_ns --session a5 --advance --step research --status complete
  local first_entry; first_entry="$(step_entry a5 research)"
  run_ns --session a5 --advance --step research --status complete
  check "A5: second --advance exits 0" 0 "$NS_RC"
  check_contains "A5: second --advance reports already=true" "already=true" "$NS_OUT"
  check "A5: projection is unchanged by the repeat" "$first_entry" "$(step_entry a5 research)"

  echo ""
  echo "=== A12: --status in_progress is refused with exit 1 ==="
  at_research a12
  run_ns --session a12 --advance --step research --status in_progress
  check "A12: --status in_progress exits 1" 1 "$NS_RC"
  # exit 1 must come from the status validation, not from --advance being unknown.
  check_not_contains "A12: the refusal is a status rejection, not an unknown-flag error" \
    "unknown option" "$NS_ERR"
  check "A12: in_progress leaves the step pending" '"pending"' "$(step_status a12 research)"
  check "A12: in_progress emits no ACTION line" 0 "$(action_line_count)"

  echo ""
  echo "=== A13: --status pending succeeds for every VALID_STEPS member ==="
  local s bad=0
  at_outline a13
  for s in $STEPS_ALL; do
    run_ns --session a13 --advance --step "$s" --status pending
    if [ "$NS_RC" -ne 0 ]; then
      bad=$((bad + 1))
      echo "  (A13: --advance --status pending failed for $s with rc=$NS_RC: $NS_ERR)"
    fi
  done
  check "A13a: every VALID_STEPS member accepts --status pending" 0 "$bad"

  # A13b: --status pending must produce the SAME projection as the existing
  # --reset subcommand (the plan calls --advance --status pending an alias of it).
  at_outline a13x
  at_outline a13y
  run_ns --session a13x --advance --step research --status pending
  run_ns --session a13y --reset research
  check "A13b: --reset still prints its unchanged stdout" \
    "RESET=research status=pending" "$NS_OUT"
  check "A13b: --advance --status pending projects identically to --reset" \
    "$(step_entry a13y research)" "$(step_entry a13x research)"

  echo ""
  echo "=== A11: no state lock file is left behind on any exit path ==="
  # exit 0 path
  at_research a11
  run_ns --session a11 --advance --step research --status complete
  check "A11a: exit 0 leaves no lock" no "$(lock_files_present)"
  # exit 3 path (skip refused — clarify_intent has no CLI-side approval route)
  run_ns --session a11 --advance --step clarify_intent --status skipped --skip-reason "not applicable here"
  check "A11b: refused skip leaves no lock" no "$(lock_files_present)"
  # exit 2 path (approval-gated completion)
  run_ns --session a11 --advance --step outline --status complete
  check "A11c: refused completion leaves no lock" no "$(lock_files_present)"
}
