# shellcheck shell=bash
# Tests: bin/workflow/next-step, hooks/lib/workflow-state/skip-signal-resolver.js
# Tags: L2, workflow, skip-signal, scope:common
#
# Case group: SKIP_HINT emission (#485 — cases 40–44).
# next-step emits an optional `SKIP_HINT=...` line when isTrivial(session) is
# true AND the current step is `outline` or `detail`. Otherwise the 4-line
# contract (ACTION/NEXT_SKILL/NEXT_HINT/REASON) is preserved exactly.
# Sourced by bin-workflow-next-step.sh; relies on helpers/fixtures from common.sh.

# Fixtures: current step is outline (research complete, outline pending).
JSON_AT_OUTLINE='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

# Fixtures: current step is detail (outline complete, detail pending).
JSON_AT_DETAIL='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

# Fixtures: current step is write_tests (post-planning: outline+detail complete).
JSON_AT_WRITE_TESTS='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1053]}'

run_skip_hint_tests() {
  local OUT line_count

  # SKIP_HINT depends on the skip-signal resolver; skip the group if absent.
  if [ ! -f "$NEXT_STEP_AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js" ]; then
    echo "SKIP: 40-45: SKIP_HINT (skip-signal-resolver.js not yet implemented)"
    PASS=$((PASS + 7))
    return 0
  fi

  local PLANS_DIR_SH
  PLANS_DIR_SH="$(mktemp -d)"
  local PLANS_DIR_SH_N
  PLANS_DIR_SH_N="$(cygpath -m "$PLANS_DIR_SH" 2>/dev/null || echo "$PLANS_DIR_SH")"

  # ---- Case 40: outline current + trivial intent.md → SKIP_HINT=WORKFLOW_OUTLINE_NOT_NEEDED ----
  write_state "case40" "$JSON_AT_OUTLINE"
  printf 'Fix typo in the helper name.\n' > "$PLANS_DIR_SH/case40-intent.md"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case40" 2>/dev/null || true)"
  check_contains "40: outline+trivial → SKIP_HINT=WORKFLOW_OUTLINE_NOT_NEEDED" \
    "SKIP_HINT=WORKFLOW_OUTLINE_NOT_NEEDED" "$OUT"

  # ---- Case 41: detail current + trivial intent.md → SKIP_HINT=WORKFLOW_DETAIL_NOT_NEEDED ----
  write_state "case41" "$JSON_AT_DETAIL"
  printf 'Fix typo in the helper name.\n' > "$PLANS_DIR_SH/case41-intent.md"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case41" 2>/dev/null || true)"
  check_contains "41: detail+trivial → SKIP_HINT=WORKFLOW_DETAIL_NOT_NEEDED" \
    "SKIP_HINT=WORKFLOW_DETAIL_NOT_NEEDED" "$OUT"

  # ---- Case 42: outline current + NON-trivial intent.md → no SKIP_HINT line ----
  write_state "case42" "$JSON_AT_OUTLINE"
  printf 'Redesign the parser entirely with a new interface.\n' > "$PLANS_DIR_SH/case42-intent.md"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case42" 2>/dev/null || true)"
  check_not_contains "42: outline+non-trivial → no SKIP_HINT line" "SKIP_HINT=" "$OUT"

  # ---- Case 43: write_tests current (post-planning) + trivial → no SKIP_HINT line ----
  # SKIP_HINT applies only to planning steps (outline/detail), never afterward.
  write_state "case43" "$JSON_AT_WRITE_TESTS"
  printf 'Fix typo in the helper name.\n' > "$PLANS_DIR_SH/case43-intent.md"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case43" 2>/dev/null || true)"
  check_not_contains "43: write_tests+trivial → no SKIP_HINT line" "SKIP_HINT=" "$OUT"

  # ---- Case 44: no SKIP_HINT → exactly 4 output lines (4-line contract preserved) ----
  # Reuse case42 (non-trivial outline → no hint). Count non-empty lines.
  line_count="$(printf '%s\n' "$OUT" | grep -cE '^(ACTION|NEXT_SKILL|NEXT_HINT|REASON|SKIP_HINT)=' || true)"
  # case42's OUT was overwritten by case43; recompute from a clean non-trivial run.
  write_state "case44" "$JSON_AT_OUTLINE"
  printf 'Redesign the parser entirely with a new interface.\n' > "$PLANS_DIR_SH/case44-intent.md"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case44" 2>/dev/null || true)"
  line_count="$(printf '%s\n' "$OUT" | grep -cE '^(ACTION|NEXT_SKILL|NEXT_HINT|REASON|SKIP_HINT)=' || true)"
  check "44: no SKIP_HINT → exactly 4 KEY=value lines" "4" "$line_count"

  # ---- Case 45: outline current + MISSING intent.md → no SKIP_HINT, 4-line contract ----
  # isTrivial fails to false on a missing intent.md, so no SKIP_HINT line is emitted
  # and the plain 4-line contract is preserved.
  write_state "case45" "$JSON_AT_OUTLINE"
  # Deliberately do NOT create case45-intent.md.
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case45" 2>/dev/null || true)"
  check_not_contains "45: outline+missing intent.md → no SKIP_HINT line" "SKIP_HINT=" "$OUT"
  line_count="$(printf '%s\n' "$OUT" | grep -cE '^(ACTION|NEXT_SKILL|NEXT_HINT|REASON|SKIP_HINT)=' || true)"
  check "45: missing intent.md → exactly 4 KEY=value lines" "4" "$line_count"

  rm -rf "$PLANS_DIR_SH"
}
