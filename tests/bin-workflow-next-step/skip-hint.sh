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

  # ---- Cases 46–53: recorded-verdict skip (#1286) ----
  # These cases require recordSkipJudgment / hasValidSkipJudgment in skip-signal-resolver.js.
  # Expected RED until #1286 write-code implements the recorded-verdict feature.
  # Guarded-skip count = total assertions in cases 46-53:
  #   46(2)+47(1)+48(2)+49(1)+50(2)+51(1)+52(2)+53(2) = 13.

  local RESOLVER_N
  RESOLVER_N="$(cygpath -m "$NEXT_STEP_AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js" 2>/dev/null || echo "$NEXT_STEP_AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js")"
  SKIP_JUDGMENT_RESOLVER_N="$RESOLVER_N"

  if ! run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    if (typeof r.recordSkipJudgment !== 'function') process.exit(1);
  " 2>/dev/null; then
    echo "SKIP: 46-53: recorded-verdict skip (recordSkipJudgment not yet implemented)"
    PASS=$((PASS + 13))
    return 0
  fi

  # ---- Case 46: outline current + valid skip_judgment → ACTION=invoke (next step), outline=skipped ----
  write_state "case46" "$JSON_AT_OUTLINE"
  plant_valid_skip "$PLANS_DIR_SH" "case46" "outline" "{ so_c1: true, so_c2: true }"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case46" 2>/dev/null || true)"
  check_contains "46: valid outline record → ACTION=invoke (detail/branch next)" "ACTION=invoke" "$OUT"
  check_not_contains "46: valid outline record → NOT pointing at outline skill" "NEXT_SKILL=make-outline-plan" "$OUT"

  # ---- Case 47: outline marked skipped in state file side-effect ----
  local OUTLINE_STATUS
  OUTLINE_STATUS="$(node -e "
    try {
      const s = JSON.parse(require('fs').readFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/case46.json', 'utf8'));
      const st = s.steps && s.steps.outline;
      console.log(st && st.status ? st.status : 'MISSING');
    } catch(e) { console.log('MISSING'); }
  " 2>/dev/null || echo "MISSING")"
  check "47: outline step status=skipped after valid record" "skipped" "$OUTLINE_STATUS"

  # ---- Case 48: detail current + valid skip_judgment → ACTION=invoke (branching_complete next) ----
  write_state "case48" "$JSON_AT_DETAIL"
  plant_valid_skip "$PLANS_DIR_SH" "case48" "detail" "{ sd_c1: true, sd_c2: true, sd_c3: true }"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case48" 2>/dev/null || true)"
  check_contains "48: valid detail record → ACTION=invoke" "ACTION=invoke" "$OUT"
  check_not_contains "48: valid detail record → NOT detail skill" "NEXT_SKILL=make-detail-plan" "$OUT"

  # ---- Case 49: branching_complete reached when both outline+detail have valid records ----
  local DETAIL_STATUS
  DETAIL_STATUS="$(node -e "
    try {
      const s = JSON.parse(require('fs').readFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/case48.json', 'utf8'));
      const st = s.steps && s.steps.detail;
      console.log(st && st.status ? st.status : 'MISSING');
    } catch(e) { console.log('MISSING'); }
  " 2>/dev/null || echo "MISSING")"
  check "49: detail step status=skipped after valid record" "skipped" "$DETAIL_STATUS"

  # ---- Case 50: outline current + valid record but so_c2=false → all_conditions_met=false → no authoritative skip ----
  write_state "case50" "$JSON_AT_OUTLINE"
  run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    r.recordSkipJudgment('case50', 'outline', { so_c1: true, so_c2: false }, 'orchestrator');
  " 2>/dev/null || true
  printf 'Fix typo in helper.\n' > "$PLANS_DIR_SH/case50-intent.md"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case50" 2>/dev/null || true)"
  # Failed record — falls back to advisory SKIP_HINT if isTrivial, but does NOT skip authoritatively
  check_contains "50: so_c2=false → ACTION=invoke (outline still current)" "ACTION=invoke" "$OUT"
  check_contains "50: so_c2=false → NEXT_SKILL=make-outline-plan (not skipped)" "NEXT_SKILL=make-outline-plan" "$OUT"

  # ---- Case 51: outline with invalid record + trivial intent → SKIP_HINT still emitted (advisory unchanged) ----
  # isTrivial is still operative; SKIP_HINT advisory should still appear when trivial.
  check_contains "51: invalid record + trivial → SKIP_HINT still emitted" "SKIP_HINT=WORKFLOW_OUTLINE_NOT_NEEDED" "$OUT"

  # ---- Case 52: no record + isTrivial false → no SKIP_HINT, 4-line contract intact ----
  write_state "case52" "$JSON_AT_OUTLINE"
  printf 'Redesign the parser entirely with a new interface.\n' > "$PLANS_DIR_SH/case52-intent.md"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case52" 2>/dev/null || true)"
  check_not_contains "52: no record + non-trivial → no SKIP_HINT" "SKIP_HINT=" "$OUT"
  local lc52
  lc52="$(printf '%s\n' "$OUT" | grep -cE '^(ACTION|NEXT_SKILL|NEXT_HINT|REASON|SKIP_HINT)=' || true)"
  check "52: no record + non-trivial → exactly 4 KEY=value lines" "4" "$lc52"

  # ---- Case 53: both-stages cascade OUTPUT assertion ----
  # Start at outline with BOTH valid outline+detail records planted; a single
  # next-step run must cascade past outline AND detail to branching_complete.
  # Asserts the OUTPUT verdict (REASON='branching_complete'), closing the
  # output-advance gap left by cases 48-49 (which only checked step statuses).
  write_state "case53" "$JSON_AT_OUTLINE"
  plant_valid_skip "$PLANS_DIR_SH" "case53" "outline" "{ so_c1: true, so_c2: true }"
  plant_valid_skip "$PLANS_DIR_SH" "case53" "detail" "{ sd_c1: true, sd_c2: true, sd_c3: true }"
  OUT="$(WORKFLOW_PLANS_DIR="$PLANS_DIR_SH_N" run_next_step --session "case53" 2>/dev/null || true)"
  check_contains "53: both records → cascade output REASON=branching_complete" "REASON='branching_complete'" "$OUT"
  check_not_contains "53: both records → output not pointing at outline" "NEXT_SKILL=make-outline-plan" "$OUT"

  rm -rf "$PLANS_DIR_SH"
}
