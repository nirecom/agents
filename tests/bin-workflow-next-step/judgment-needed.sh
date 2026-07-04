# shellcheck shell=bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, judgment-needed, scope:issue-specific
#
# Case group: judgment_needed ACTION emission (#1259).
# When next-step resolves outline or detail as the current step, it emits
# ACTION=judgment_needed (not ACTION=invoke), directing the orchestrator
# to semantically decide whether to skip the stage.
# Sourced by bin-workflow-next-step.sh; relies on helpers/fixtures from common.sh.

# Fixture: detail pending, outline complete, all preceding complete.
JSON_AT_DETAIL_OUTLINE_COMPLETE='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1259]}'

# Fixture: detail pending, outline skipped (no outline.md produced).
JSON_DETAIL_OUTLINE_SKIPPED='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"skipped"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1259]}'

run_judgment_needed_tests() {
  local OUT

  # ---- N1: outline pending → ACTION=judgment_needed, NEXT_SKILL=make-outline-plan ----
  write_state "jn-n1" "$JSON_AT_OUTLINE"
  OUT="$(run_next_step --session "jn-n1" 2>/dev/null || true)"
  check "N1a: outline pending → ACTION=judgment_needed" \
    "judgment_needed" "$(printf '%s\n' "$OUT" | grep '^ACTION=' | cut -d= -f2)"
  check "N1b: outline pending → NEXT_SKILL=make-outline-plan" \
    "make-outline-plan" "$(printf '%s\n' "$OUT" | grep '^NEXT_SKILL=' | cut -d= -f2)"
  check_contains "N1c: outline pending → NEXT_HINT mentions intent.md" \
    "intent.md" "$OUT"

  # ---- N2: detail pending + outline complete → ACTION=judgment_needed, NEXT_HINT mentions outline.md ----
  write_state "jn-n2" "$JSON_AT_DETAIL_OUTLINE_COMPLETE"
  OUT="$(run_next_step --session "jn-n2" 2>/dev/null || true)"
  check "N2a: detail pending (outline complete) → ACTION=judgment_needed" \
    "judgment_needed" "$(printf '%s\n' "$OUT" | grep '^ACTION=' | cut -d= -f2)"
  check_contains "N2b: detail pending (outline complete) → NEXT_HINT mentions outline.md" \
    "outline.md" "$OUT"

  # ---- N3: detail pending + outline absent from state → NEXT_HINT mentions intent.md fallback ----
  local JSON_DETAIL_NO_OUTLINE_KEY
  JSON_DETAIL_NO_OUTLINE_KEY='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1259]}'
  write_state "jn-n3" "$JSON_DETAIL_NO_OUTLINE_KEY"
  OUT="$(run_next_step --session "jn-n3" 2>/dev/null || true)"
  check "N3a: detail pending (outline absent) → ACTION=judgment_needed" \
    "judgment_needed" "$(printf '%s\n' "$OUT" | grep '^ACTION=' | cut -d= -f2)"
  check_contains "N3b: detail pending (outline absent) → NEXT_HINT mentions intent.md" \
    "intent.md" "$OUT"

  # ---- N4: detail pending + outline=skipped → NEXT_HINT mentions intent.md fallback ----
  write_state "jn-n4" "$JSON_DETAIL_OUTLINE_SKIPPED"
  OUT="$(run_next_step --session "jn-n4" 2>/dev/null || true)"
  check "N4a: detail pending (outline skipped) → ACTION=judgment_needed" \
    "judgment_needed" "$(printf '%s\n' "$OUT" | grep '^ACTION=' | cut -d= -f2)"
  check_contains "N4b: detail pending (outline skipped) → NEXT_HINT mentions intent.md" \
    "intent.md" "$OUT"

  # ---- N5: judgment_needed does NOT write to state file (no markStep called) ----
  local STATE_BEFORE STATE_AFTER
  write_state "jn-n5" "$JSON_AT_OUTLINE"
  STATE_BEFORE="$(cat "$TMPDIR_WT/jn-n5.json" 2>/dev/null || echo "MISSING")"
  run_next_step --session "jn-n5" > /dev/null 2>&1 || true
  STATE_AFTER="$(cat "$TMPDIR_WT/jn-n5.json" 2>/dev/null || echo "MISSING")"
  check "N5: judgment_needed does not mutate state file" \
    "$STATE_BEFORE" "$STATE_AFTER"

  # ---- N6: write_tests pending (post-detail, both outline+detail complete) → ACTION=invoke ----
  write_state "jn-n6" "$JSON_AT_WRITE_TESTS"
  OUT="$(run_next_step --session "jn-n6" 2>/dev/null || true)"
  check "N6: write_tests pending → ACTION=invoke (not judgment_needed)" \
    "invoke" "$(printf '%s\n' "$OUT" | grep '^ACTION=' | cut -d= -f2)"

  # ---- N7: outline=in_progress → judgment_needed for outline, not detail (sequential eval) ----
  # When outline is mid-execution (in_progress), detail is not yet the current step.
  # judgment_needed fires for outline; NEXT_SKILL=make-outline-plan (not make-detail-plan).
  local JSON_OUTLINE_IN_PROGRESS
  JSON_OUTLINE_IN_PROGRESS='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"in_progress"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1259]}'
  write_state "jn-n7" "$JSON_OUTLINE_IN_PROGRESS"
  OUT="$(run_next_step --session "jn-n7" 2>/dev/null || true)"
  check "N7a: outline=in_progress → ACTION=judgment_needed (sequential: detail not evaluated yet)" \
    "judgment_needed" "$(printf '%s\n' "$OUT" | grep '^ACTION=' | cut -d= -f2)"
  check "N7b: outline=in_progress → NEXT_SKILL=make-outline-plan (not make-detail-plan)" \
    "make-outline-plan" "$(printf '%s\n' "$OUT" | grep '^NEXT_SKILL=' | cut -d= -f2)"
}
