# shellcheck shell=bash
# Tests: bin/workflow/next-step, hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/plan-skip-allowance.js, hooks/workflow-mark/not-needed-handlers.js
# Tags: tl2, workflow, advance, skip-allowance, scope:issue-specific
# #1644 cases A2 / A3 / A4 / A8 / A9 / A10 / A16. Relies on helpers.sh.

run_gate_cases() {
  echo ""
  echo "=== A2: a failed record emits ZERO ACTION lines and exits 2 ==="
  # A regular file at the workflow-dir path makes every write fail with ENOTDIR,
  # deterministically and without touching the fixture state files.
  local block="$TMPDIR_BASE/wfblock" block_n errf="$TMPDIR_BASE/ns.err"
  : > "$block"
  block_n="$(nrm "$block")"
  NS_RC=0
  NS_OUT="$(CLAUDE_WORKFLOW_DIR="$block_n" run_with_timeout node "$NEXT_STEP_N" \
    --session a2 --advance --step research --status complete --next 2>"$errf")" || NS_RC=$?
  NS_ERR="$(cat "$errf" 2>/dev/null || echo "")"
  check "A2a: write failure exits 2" 2 "$NS_RC"
  check "A2b: write failure emits no ACTION line" 0 "$(action_line_count)"
  check_not_contains "A2c: write failure emits no NEXT_SKILL line" "NEXT_SKILL=" "$NS_OUT"

  echo ""
  echo "=== A3: approval-gated complete via --advance is refused and names the sentinel ==="
  # CONFIRM_OUTLINE / CONFIRM_DETAIL are deliberately absent from the fixture .env
  # so the approval invariant is armed (never inherited from the repo's .env).
  at_outline a3
  run_ns --session a3 --advance --step outline --status complete
  check "A3a: unapproved outline complete exits 2" 2 "$NS_RC"
  check_contains "A3a: stderr names WORKFLOW_CONFIRM_OUTLINE" "WORKFLOW_CONFIRM_OUTLINE" "$NS_ERR"
  check "A3a: outline is not completed" '"pending"' "$(step_status a3 outline)"
  check "A3a: no ACTION line on refusal" 0 "$(action_line_count)"

  make_state a3d "workflow_init clarify_intent research outline"
  run_ns --session a3d --advance --step detail --status complete
  check "A3b: unapproved detail complete exits 2" 2 "$NS_RC"
  check_contains "A3b: stderr names WORKFLOW_CONFIRM_DETAIL" "WORKFLOW_CONFIRM_DETAIL" "$NS_ERR"

  echo ""
  echo "=== A4: manual-mark-forbidden steps cannot be completed via --advance ==="
  local st
  for st in user_verification review_tests docs; do
    at_outline "a4$st"
    run_ns --session "a4$st" --advance --step "$st" --status complete
    check "A4: --advance --step $st --status complete exits 2" 2 "$NS_RC"
    check "A4: $st is not recorded complete" '"pending"' "$(step_status "a4$st" "$st")"
    check "A4: $st refusal emits no ACTION line" 0 "$(action_line_count)"
  done
  # The user_verification arm is the one that keeps settings.json's deny rule and
  # the ask-gated WORKFLOW_USER_VERIFIED sentinel from being routed around.
  at_outline a4uvhint
  run_ns --session a4uvhint --advance --step user_verification --status complete
  check_contains "A4: user_verification refusal names WORKFLOW_USER_VERIFIED" \
    "WORKFLOW_USER_VERIFIED" "$NS_ERR"

  echo ""
  echo "=== A8: --status skipped outside getSkippableSteps() exits 3 ==="
  for st in docs branching_complete user_verification pre_final_report_gate workflow_init; do
    # Every member must start PENDING, otherwise "is not recorded skipped" is
    # unfalsifiable for it. at_outline already marks workflow_init complete, so
    # that member gets an all-pending fixture instead.
    if [ "$st" = "workflow_init" ]; then make_state "a8$st" ""; else at_outline "a8$st"; fi
    check "A8: $st starts pending" '"pending"' "$(step_status "a8$st" "$st")"
    run_ns --session "a8$st" --advance --step "$st" --status skipped --skip-reason "not applicable to this change"
    check "A8: skip of non-skippable $st exits 3" 3 "$NS_RC"
    check "A8: $st is not recorded skipped" '"pending"' "$(step_status "a8$st" "$st")"
  done

  echo ""
  echo "=== A9: clarify_intent / review_security skips are always refused ==="
  at_outline a9ci
  run_ns --session a9ci --advance --step clarify_intent --status skipped --skip-reason "task is fully specified"
  check "A9a: clarify_intent skip exits 3" 3 "$NS_RC"
  check_contains "A9a: stderr names the sentinel literal" \
    "WORKFLOW_CLARIFY_INTENT_NOT_NEEDED" "$NS_ERR"
  at_outline a9rs
  run_ns --session a9rs --advance --step review_security --status skipped --skip-reason "no security surface touched"
  check "A9b: review_security skip exits 3" 3 "$NS_RC"
  check_contains "A9b: stderr names the sentinel literal" \
    "WORKFLOW_REVIEW_SECURITY_NOT_NEEDED" "$NS_ERR"

  echo ""
  echo "=== A10: BUGFIX sessions refuse write_tests skip on BOTH paths ==="
  # CONFIRM_TESTS=off is pinned in a config FILE so the CLI path's only remaining
  # blocker is the BUGFIX rule itself (#1147 D1) — not a missing off-switch.
  local cfg_tests_off="$TMPDIR_BASE/cfg-tests-off" cfg_tests_off_n
  mkdir -p "$cfg_tests_off"
  printf 'CONFIRM_TESTS=off\n' > "$cfg_tests_off/.env"
  cfg_tests_off_n="$(nrm "$cfg_tests_off")"

  at_outline a10 ',"git_branch":"fix/advance-bugfix"'
  NS_RC=0
  NS_OUT="$(AGENTS_CONFIG_DIR="$cfg_tests_off_n" CONFIRM_TESTS= run_with_timeout node "$NEXT_STEP_N" \
    --session a10 --advance --step write_tests --status skipped \
    --skip-reason "no behavior change in this fix" 2>"$errf")" || NS_RC=$?
  NS_ERR="$(cat "$errf" 2>/dev/null || echo "")"
  check "A10a: CLI write_tests skip in a BUGFIX session exits 3" 3 "$NS_RC"
  check "A10a: write_tests stays pending on the CLI path" '"pending"' "$(step_status a10 write_tests)"

  at_outline a10s ',"git_branch":"fix/advance-bugfix"'
  run_mark_hook a10s 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: no behavior change in this fix>>"'
  check "A10b: sentinel path also leaves write_tests pending in a BUGFIX session" \
    '"pending"' "$(step_status a10s write_tests)"

  echo ""
  echo "=== A16: CONFIRM_TESTS can only be waived by the config FILE ==="
  # Inline prefix forgery: process.env says off, the config file does not.
  at_outline a16f
  NS_RC=0
  NS_OUT="$(CONFIRM_TESTS=off run_with_timeout node "$NEXT_STEP_N" \
    --session a16f --advance --step write_tests --status skipped \
    --skip-reason "docs-only change, no tests to write" 2>"$errf")" || NS_RC=$?
  NS_ERR="$(cat "$errf" 2>/dev/null || echo "")"
  check "A16a: inline CONFIRM_TESTS=off prefix does NOT waive the gate (exit 3)" 3 "$NS_RC"
  check "A16a: write_tests stays pending under forged env" '"pending"' "$(step_status a16f write_tests)"

  # Config-file value: the only sanctioned waiver for the CLI path.
  at_outline a16c
  NS_RC=0
  NS_OUT="$(AGENTS_CONFIG_DIR="$cfg_tests_off_n" run_with_timeout node "$NEXT_STEP_N" \
    --session a16c --advance --step write_tests --status skipped \
    --skip-reason "docs-only change, no tests to write" 2>"$errf")" || NS_RC=$?
  NS_ERR="$(cat "$errf" 2>/dev/null || echo "")"
  check "A16b: config-file CONFIRM_TESTS=off allows the skip (exit 0)" 0 "$NS_RC"
  check "A16b: write_tests is recorded skipped" '"skipped"' "$(step_status a16c write_tests)"
  # #833 symmetric propagation is owned by the same single writer.
  check "A16b: review_tests is skipped symmetrically" '"skipped"' "$(step_status a16c review_tests)"
}
