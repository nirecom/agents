# shellcheck shell=bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, scope:common
#
# Case group: --list renderer + schema/idempotency/security boundary (cases 14–23).
# Sourced by bin-workflow-next-step.sh; relies on helpers/fixtures from common.sh.

run_list_render_tests() {
  local OUT ACTION NEXT_SKILL NEXT_HINT REASON

  # ---- Case 14: --list (no session) ----------------------------------------
  local LIST_OUT LINE_COUNT
  LIST_OUT="$(run_next_step --list 2>/dev/null || true)"
  LINE_COUNT="$(printf '%s\n' "$LIST_OUT" | grep -c . || true)"
  check "14a: --list emits 14 rows" "14" "$LINE_COUNT"

  local step
  local missing=0
  for step in workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate; do
    if ! echo "$LIST_OUT" | grep -qF "$step"; then
      echo "FAIL: 14b: --list missing step name [$step]"
      FAIL=$((FAIL + 1))
      missing=1
    fi
  done
  if [ "$missing" = "0" ]; then
    echo "PASS: 14b: --list contains all 14 step names"
    PASS=$((PASS + 1))
  fi

  # Each row matches "<digits><whitespace><snake_case>"
  local row_fail=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if ! echo "$line" | grep -Eq '[0-9]+[[:space:]]+[a-z_]+'; then
      echo "FAIL: 14c: row does not match index+name pattern -- [$line]"
      FAIL=$((FAIL + 1))
      row_fail=1
      break
    fi
  done <<< "$LIST_OUT"
  if [ "$row_fail" = "0" ]; then
    echo "PASS: 14c: every --list row matches index+name pattern"
    PASS=$((PASS + 1))
  fi

  # ---- Case 15: --list --session <sid> with mixed state --------------------
  write_state "case15" "$JSON_LIST_MIXED"
  local MIXED_OUT
  MIXED_OUT="$(run_next_step --list --session "case15" 2>/dev/null || true)"

  local line_wf line_research line_outline line_detail
  line_wf="$(echo "$MIXED_OUT" | grep -E 'workflow_init([^a-z_]|$)' | head -n1 || true)"
  line_research="$(echo "$MIXED_OUT" | grep -E 'research([^a-z_]|$)' | head -n1 || true)"
  line_outline="$(echo "$MIXED_OUT" | grep -E 'outline([^a-z_]|$)' | head -n1 || true)"
  line_detail="$(echo "$MIXED_OUT" | grep -E 'detail([^a-z_]|$)' | head -n1 || true)"

  check_contains "15a: complete step shows [x]" "[x]" "$line_wf"
  check_contains "15b: skipped step shows [-]" "[-]" "$line_research"
  check_contains "15c: complete step (outline) shows [x]" "[x]" "$line_outline"
  check_contains "15d: current step (detail) shows [*]" "[*]" "$line_detail"

  # branching_complete is pending -> should show "[ ]"
  local line_branching
  line_branching="$(echo "$MIXED_OUT" | grep -E 'branching_complete' | head -n1 || true)"
  check_contains "15e: pending step shows [ ]" "[ ]" "$line_branching"

  # ---- Case 16: --list [!] blocked overlay ---------------------------------
  write_state "case16" "$JSON_BLOCKED"
  local BLOCKED_LIST
  BLOCKED_LIST="$(run_next_step --list --session "case16" 2>/dev/null || true)"
  local line_clarify
  line_clarify="$(echo "$BLOCKED_LIST" | grep -E 'clarify_intent' | head -n1 || true)"
  check_contains "16: clarify_intent row shows [!] overlay" "[!]" "$line_clarify"

  # ---- Case 17: --list --session <missing-sid> -----------------------------
  local PLAIN_LIST MISSING_LIST
  PLAIN_LIST="$(run_next_step --list 2>/dev/null || true)"
  MISSING_LIST="$(run_next_step --list --session "absent-sid-xyz-$$" 2>/dev/null || true)"
  check "17: --list with missing sid matches plain --list" "$PLAIN_LIST" "$MISSING_LIST"

  # ---- Case 18: missing-step schema ----------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case18" "$JSON_MISSING_STEP"
  OUT="$(run_next_step --session "case18" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "18: missing-step ACTION=invoke" "invoke" "${ACTION:-}"
  check "18: missing-step NEXT_SKILL=survey-code" "survey-code" "${NEXT_SKILL:-}"

  # ---- Case 18b: empty steps object ----------------------------------------
  # Migration synthesizes complete for workflow_init, clarify_intent, branching_complete
  # when all keys are absent — inconsistent with absent research (pending) at idx 2.
  ACTION=""; REASON=""
  write_state "case18b" "$JSON_EMPTY_STEPS"
  OUT="$(run_next_step --session "case18b" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "18b: empty-steps ACTION=abort" "abort" "${ACTION:-}"
  check_contains "18b: empty-steps REASON marker" "inconsistent:" "${REASON:-}"

  # ---- Case 19: idempotency -------------------------------------------------
  write_state "case19" "$JSON_WFINIT_COMPLETE"
  local OUT1 OUT2
  OUT1="$(run_next_step --session "case19" 2>/dev/null || true)"
  OUT2="$(run_next_step --session "case19" 2>/dev/null || true)"
  check "19: idempotency same output on re-run" "$OUT1" "$OUT2"

  # ---- Case 20: security -- path traversal in --session arg ----------------
  # next-step now validates --session against [A-Za-z0-9_-]+ → exits non-zero.
  rc=0
  run_next_step --session "../evil-$$" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 20: path-traversal --session rejected (exit $rc)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 20: path-traversal --session should be rejected"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 20b: security -- shell metachar injection in --session arg ------
  # Validation rejects meta characters ([A-Za-z0-9_-]+ allowlist) → exits non-zero.
  rc=0
  run_next_step --session 'foo;bar$(evil)' 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 20b: metachar injection rejected (exit $rc)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 20b: metachar injection should be rejected"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 20c: empty string session boundary ------------------------------
  ACTION=""
  OUT="$(run_next_step --session "" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  if [ -n "${ACTION:-}" ]; then
    echo "PASS: 20c: empty session yields valid ACTION (${ACTION})"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 20c: empty session produced empty ACTION (silent crash)"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 21: --list shows [*] for in_progress step ----------------------
  write_state "case21" "$JSON_WRITE_TESTS_IN_PROGRESS"
  local IN_PROG_LIST line_write_tests
  IN_PROG_LIST="$(run_next_step --list --session "case21" 2>/dev/null || true)"
  line_write_tests="$(echo "$IN_PROG_LIST" | grep -E 'write_tests' | head -n1 || true)"
  check_contains "21: in_progress step shows [*] in --list" "[*]" "$line_write_tests"

  # ---- Case 22a: non-skill step (branching_complete) — NEXT_SKILL empty -----
  ACTION=""; NEXT_SKILL="SENTINEL"; NEXT_HINT=""
  write_state "case22a" "$JSON_BRANCHING_NEXT"
  OUT="$(run_next_step --session "case22a" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "22a: branching_complete ACTION=invoke" "invoke" "${ACTION:-}"
  check "22a: branching_complete NEXT_SKILL empty" "" "${NEXT_SKILL:-}"
  if [ -n "${NEXT_HINT:-}" ]; then
    echo "PASS: 22a: branching_complete NEXT_HINT non-empty"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 22a: branching_complete NEXT_HINT should be non-empty"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 22b: non-skill step (user_verification) — NEXT_SKILL empty ------
  ACTION=""; NEXT_SKILL="SENTINEL"; NEXT_HINT=""
  write_state "case22b" "$JSON_USER_VERIFICATION_NEXT"
  OUT="$(run_next_step --session "case22b" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "22b: user_verification ACTION=invoke" "invoke" "${ACTION:-}"
  check "22b: user_verification NEXT_SKILL empty" "" "${NEXT_SKILL:-}"
  if [ -n "${NEXT_HINT:-}" ]; then
    echo "PASS: 22b: user_verification NEXT_HINT non-empty"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 22b: user_verification NEXT_HINT should be non-empty"
    FAIL=$((FAIL + 1))
  fi

  # ---- Case 23: unknown CLI flag → exit non-zero ----------------------------
  local unk_rc=0
  run_next_step --unknown-flag-xyz >/dev/null 2>/dev/null || unk_rc=$?
  if [ "$unk_rc" -ne 0 ]; then
    echo "PASS: 23: unknown flag exits non-zero ($unk_rc)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 23: unknown flag should exit non-zero but exited 0"
    FAIL=$((FAIL + 1))
  fi
}
