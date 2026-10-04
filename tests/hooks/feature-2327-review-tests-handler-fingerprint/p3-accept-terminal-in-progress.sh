#!/usr/bin/env bash
# Tests: hooks/workflow-mark/review-tests-handler.js, hooks/workflow-state/state-io/review-tests.js
# Tags: tl2, workflow, review-tests, warnings-accepted, scope:issue-specific, pwsh-not-required

# TL3 gap (what this test does NOT catch):
# - a real claude -p session firing the PostToolUse hook for the ACCEPTED sentinel
# - next-step driven by live session-state resolution (no --session flag)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

# Sourced by feature-2327-review-tests-handler-fingerprint.sh (harness, TMPDIR, counters live there).
# #2491: in_progress + terminal marker -> complete via WARNINGS_ACCEPTED.
# Helpers (seed_state, send_cmd, sv, make_repo, check*) come from p2.

write_terminal_marker() {
  # The #1361 terminal marker lives in <sid>.control/ since #2434; marker_exists also checks the legacy name.
  mkdir -p "$WORKFLOW_STATE_DIR/${1}.control"
  if [ -n "${3:-}" ]; then
    printf '%s\n%s\n' "$2" "$3" > "$WORKFLOW_STATE_DIR/${1}.control/test-review-terminal.txt"
  else
    printf '%s\n' "$2" > "$WORKFLOW_STATE_DIR/${1}.control/test-review-terminal.txt"
  fi
}
marker_exists() { [ -f "$WORKFLOW_STATE_DIR/${1}.control/test-review-terminal.txt" ] || [ -f "$WORKFLOW_PLANS_DIR/${1}-test-review-terminal.txt" ]; }
marker_state() { if marker_exists "$1"; then printf 'present'; else printf 'deleted'; fi; }

STALE_RT='{"status":"in_progress","reopen_reason":"write-code-stale","warnings_summary":"warnings=2"}'

case_begin "ti1-in-progress-terminal-rc6-completes" "hooks/workflow-state/state-io/review-tests.js"
T1="$TMPDIR_BASE/t1"; T1_N="$(np "$T1")"
make_repo "$T1"
seed_state ti1sid "$STALE_RT" complete
write_terminal_marker ti1sid 6 fp1
TI1_OUT="$(send_cmd ti1sid "$T1_N" "$(accept_cmd "$REASON")")"
check "TI1: status complete" "complete" "$(sv ti1sid status)"
check "TI1: reopen_reason cleared" "none" "$(sv ti1sid reopen)"
check "TI1: warnings_summary gone" "gone" "$(sv ti1sid summary)"
check_contains "TI1: output says terminal review accepted" "terminal review accepted" "$TI1_OUT"
check "TI1: marker deleted" "deleted" "$(marker_state ti1sid)"
check "TI1: manifest records current impl oid" "$IMPL_OID" "$(sv ti1sid impl)"
check "TI1: freshness is fresh after accept" "true:match" "$(fresh ti1sid "$T1_N")"
check "TI1: acceptance reason stored" "$REASON" "$(sv ti1sid reason)"
TI1_NS="$(cd "$T1_N" && CLAUDE_PROJECT_DIR="$T1_N" run_with_timeout 60 node "$NEXT_STEP_N" --session ti1sid 2>/dev/null)"
check_not_contains "TI1: next skill is no longer review-tests" "NEXT_SKILL=review-tests" "$TI1_NS"
case_end

case_begin "ti2-in-progress-terminal-rc2-completes" "hooks/workflow-state/state-io/review-tests.js"
T2="$TMPDIR_BASE/t2"; T2_N="$(np "$T2")"
make_repo "$T2"
seed_state ti2sid "$STALE_RT" complete
write_terminal_marker ti2sid 2 fp2
send_cmd ti2sid "$T2_N" "$(accept_cmd "$REASON")" >/dev/null
check "TI2: status complete (rc=2 valid terminal)" "complete" "$(sv ti2sid status)"
case_end

case_begin "ti3-in-progress-without-reopen-reason-completes" "hooks/workflow-state/state-io/review-tests.js"
T3="$TMPDIR_BASE/t3"; T3_N="$(np "$T3")"
make_repo "$T3"
seed_state ti3sid '{"status":"in_progress"}' complete
write_terminal_marker ti3sid 6 fp3
send_cmd ti3sid "$T3_N" "$(accept_cmd "$REASON")" >/dev/null
check "TI3: status complete without reopen_reason" "complete" "$(sv ti3sid status)"
check "TI3: manifest records current impl oid" "$IMPL_OID" "$(sv ti3sid impl)"
check "TI3: freshness is fresh after accept" "true:match" "$(fresh ti3sid "$T3_N")"
check "TI3: acceptance reason stored" "$REASON" "$(sv ti3sid reason)"
case_end

case_begin "ti4-in-progress-no-marker-nothing-to-accept" "hooks/workflow-mark/review-tests-handler.js"
T4="$TMPDIR_BASE/t4"; T4_N="$(np "$T4")"
make_repo "$T4"
seed_state ti4sid '{"status":"in_progress"}' complete
TI4_OUT="$(send_cmd ti4sid "$T4_N" "$(accept_cmd "$REASON")")"
check "TI4: stays in_progress" "in_progress" "$(sv ti4sid status)"
check_contains "TI4: output says nothing to accept" "nothing to accept" "$TI4_OUT"
case_end

case_begin "ti5-in-progress-no-marker-clears-warnings" "hooks/workflow-state/state-io/review-tests.js"
T5="$TMPDIR_BASE/t5"; T5_N="$(np "$T5")"
make_repo "$T5"
seed_state ti5sid '{"status":"in_progress","warnings_summary":"warnings=2"}' complete
send_cmd ti5sid "$T5_N" "$(accept_cmd "$REASON")" >/dev/null
check "TI5: warnings_summary cleared" "gone" "$(sv ti5sid summary)"
check "TI5: stays in_progress" "in_progress" "$(sv ti5sid status)"
case_end

case_begin "ti6-ti7-ti11-non-terminal-marker-stays-in-progress" "hooks/workflow-state/state-io/review-tests.js"
T6="$TMPDIR_BASE/t6"; T6_N="$(np "$T6")"
make_repo "$T6"
for TI_RC in 3 7 "" abc; do
  TI_SID="ti6rc${TI_RC:-empty}sid"
  seed_state "$TI_SID" '{"status":"in_progress"}' complete
  write_terminal_marker "$TI_SID" "$TI_RC" fpx
  send_cmd "$TI_SID" "$T6_N" "$(accept_cmd "$REASON")" >/dev/null
  check "TI6/7/11: rc=[$TI_RC] stays in_progress (fail-closed)" "in_progress" "$(sv "$TI_SID" status)"
done
case_end

case_begin "ti8-terminal-marker-manifest-unavailable-fail-closed" "hooks/workflow-mark/review-tests-handler.js"
seed_state ti8sid '{"status":"in_progress"}' complete
write_terminal_marker ti8sid 6 fp8
TI8_OUT="$(send_cmd ti8sid "$P2_NOGIT_N" "$(accept_cmd "$REASON")")"
check "TI8: stays in_progress" "in_progress" "$(sv ti8sid status)"
check "TI8: marker NOT deleted" "present" "$(marker_state ti8sid)"
check_contains "TI8: output says manifest unavailable" "manifest unavailable" "$TI8_OUT"
case_end

case_begin "ti9-terminal-accept-idempotent-second-send" "hooks/workflow-mark/review-tests-handler.js"
TI9_OUT="$(send_cmd ti1sid "$T1_N" "$(accept_cmd "$REASON")")"
check "TI9: status stays complete" "complete" "$(sv ti1sid status)"
check_not_contains "TI9: no write failure reported" "failed to write state" "$TI9_OUT"
case_end

case_begin "ti10-pending-reopened-with-marker-uses-existing-recovery" "hooks/workflow-state/state-io/review-tests.js"
T10="$TMPDIR_BASE/t10"; T10_N="$(np "$T10")"
make_repo "$T10"
seed_state ti10sid "{\"status\":\"pending\",\"reopen_reason\":\"write-code-stale\",\"review_scope_manifest\":$OLD_MANIFEST}" complete
write_terminal_marker ti10sid 6 fp10
send_cmd ti10sid "$T10_N" "$(accept_cmd "$REASON")" >/dev/null
check "TI10: pending recovered to complete" "complete" "$(sv ti10sid status)"
check "TI10: reopen_reason cleared" "none" "$(sv ti10sid reopen)"
case_end

case_begin "ti12-pending-without-reopen-reason-stays-pending" "hooks/workflow-state/state-io/review-tests.js"
T12="$TMPDIR_BASE/t12"; T12_N="$(np "$T12")"
make_repo "$T12"
seed_state ti12sid '{"status":"pending"}' complete
write_terminal_marker ti12sid 6 fp12
TI12_OUT="$(send_cmd ti12sid "$T12_N" "$(accept_cmd "$REASON")")"
check "TI12: pending without reopen_reason stays pending" "pending" "$(sv ti12sid status)"
check_contains "TI12: output says nothing to accept" "nothing to accept" "$TI12_OUT"
case_end
