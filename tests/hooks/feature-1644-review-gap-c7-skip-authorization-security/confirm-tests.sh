# shellcheck shell=bash
# Tests: hooks/workflow-state/plan-skip-allowance.js, hooks/lib/plan-confirm-flag.js, hooks/lib/load-env.js, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, skip-authorization, confirm-tests, config-dependent, classifier, scope:issue-specific
# C7 group 1 — the CONFIRM_TESTS axis: both classifier verdicts plus the
# loader's value-normalization matrix. Sourced by the dispatcher.

run_confirm_cases() {
  echo "=== C7-1: CONFIRM_TESTS=off in the config FILE authorizes the skip ==="
  at_write_tests w1
  run_ns "$REPO_CODE" "$CFG_OFF" "$REPO_CODE_N" -- \
    --session w1 --advance --step write_tests --status skipped --skip-reason "$REASON"
  check "C7-1: exit 0" 0 "$RC"
  check_contains "C7-1: the advance line names write_tests" "ADVANCED=write_tests status=skipped" "$OUT"
  check "C7-1: write_tests is skipped" '"skipped"' "$(step_status w1 write_tests)"
  # #833 symmetric propagation: no tests to write means no tests to review.
  # Pinned here because it is the authorized branch's full side effect, and a
  # partial implementation that skipped only write_tests would strand review_tests.
  check "C7-1: review_tests is skipped symmetrically" '"skipped"' "$(step_status w1 review_tests)"

  echo ""
  echo "=== C7-2: the symmetric counterparts refuse (CPR-ORTH classifier coverage) ==="
  at_write_tests w2a
  STATE_BEFORE="$(state_bytes w2a)"; REPO_BEFORE="$(repo_fingerprint "$REPO_CODE")"
  run_ns "$REPO_CODE" "$CFG_ON" "$REPO_CODE_N" -- \
    --session w2a --advance --step write_tests --status skipped --skip-reason "$REASON"
  assert_refused "C7-2a CONFIRM_TESTS=on" w2a write_tests
  check_contains "C7-2a: the diagnostic names the config FILE requirement" \
    "set CONFIRM_TESTS=off in the agents config FILE" "$ERR"
  check_contains "C7-2a: ...and states that an inline prefix is not accepted" \
    "an inline environment prefix is not accepted" "$ERR"
  check "C7-2a: review_tests is not dragged along by a refused skip" \
    '"pending"' "$(step_status w2a review_tests)"

  at_write_tests w2b
  STATE_BEFORE="$(state_bytes w2b)"; REPO_BEFORE="$(repo_fingerprint "$REPO_CODE")"
  run_ns "$REPO_CODE" "$CFG_UNSET" "$REPO_CODE_N" -- \
    --session w2b --advance --step write_tests --status skipped --skip-reason "$REASON"
  assert_refused "C7-2b CONFIRM_TESTS unset" w2b write_tests

  echo ""
  echo "=== C7-3: value normalization by the loader (pinned as observed) ==="
  # CASE-INSENSITIVITY: plan-confirm-flag.js isConfirmOffForStageFromFile compares
  # String(raw).toLowerCase() against the exact literal "off", so an uppercase OFF
  # in the file IS accepted.
  at_write_tests w3a
  run_ns "$REPO_CODE" "$CFG_UPPER" "$REPO_CODE_N" -- \
    --session w3a --advance --step write_tests --status skipped --skip-reason "$REASON"
  check "C7-3a: an uppercase OFF in the file authorizes the skip" 0 "$RC"
  check "C7-3a: write_tests is skipped" '"skipped"' "$(step_status w3a write_tests)"

  # WHITESPACE PADDING, unquoted: load-env.js parseEnv trims the whole LINE and
  # its KEY\s*=\s*(.*) grammar eats the padding, so `CONFIRM_TESTS=   off`
  # reaches the comparison as the bare literal and IS accepted. The padding never
  # survives the parser — it is not the comparison that tolerates it.
  at_write_tests w3b
  run_ns "$REPO_CODE" "$CFG_PAD" "$REPO_CODE_N" -- \
    --session w3b --advance --step write_tests --status skipped --skip-reason "$REASON"
  check "C7-3b: unquoted padding is stripped by the parser and the skip is allowed" 0 "$RC"
  check "C7-3b: write_tests is skipped" '"skipped"' "$(step_status w3b write_tests)"

  # WHITESPACE PADDING, QUOTED: the quotes protect the padding from the line trim,
  # and isConfirmOffForStageFromFile does NOT .trim() before comparing (unlike the
  # sentinel-door read in plan-skip-allowance.js, which does). So `" off "` is
  # REFUSED. Pinned as the observed asymmetry between the two doors; it fails
  # SAFE (a padded value never opens the gate), so it is recorded, not filed.
  at_write_tests w3c
  STATE_BEFORE="$(state_bytes w3c)"; REPO_BEFORE="$(repo_fingerprint "$REPO_CODE")"
  run_ns "$REPO_CODE" "$CFG_PAD_QUOTED" "$REPO_CODE_N" -- \
    --session w3c --advance --step write_tests --status skipped --skip-reason "$REASON"
  assert_refused "C7-3c a quoted padded value fails safe to on" w3c write_tests
}
